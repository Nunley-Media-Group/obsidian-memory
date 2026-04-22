# Design: RAG prompt injection hook

**Issues**: #10, #5
**Date**: 2026-04-21
**Status**: Amended
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
│  hooks/hooks.json                       │
│   UserPromptSubmit[0].hooks[0].command =                        │
│     ${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ stdin: { "prompt": "…" }
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/vault-rag.sh                   │
│   1. guard: jq present? config readable? rag.enabled?           │
│   2. read prompt from stdin via jq                              │
│   3. tokenize → stopword filter → dedupe → cap at 6             │
│   4. build alternation regex                                    │
│   5. single-pass scoring across vault (rg -c, else find|xargs  │
│      grep -c), excluding .obsidian/ and .trash/                 │
│   6. sort -rn, head -n 5                                        │
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
Single pass: rg -c -i --glob '*.md' --glob '!.obsidian/**' --glob '!.trash/**'
  -e REGEX "$VAULT"   (fallback: find -prune ... -print0 | xargs -0 grep -c -i -E)
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

**Wiring** (`hooks/hooks.json`):

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
- [x] **Parallelism**: None needed. Scoring is a single `rg -c` (or `xargs -0 grep -c`) invocation that walks the whole vault in one process — no per-file subprocess spawn. On a 10k-note vault this stays well under 300 ms because the subprocess fork cost is paid once, not N times.
- [x] **Fast-path via `rg`**: `rg -c` performs the walk + match in a single process with mmap'd IO; no separate `rg --files` enumerate step is needed.
- [x] **Fallback cost**: `find … -print0 | xargs -0 grep -c -i -E` batches all candidates into a small number of grep invocations. ~3–5× slower than `rg` but still one-shot, not per-file.
- [x] **Payload size**: 5 files × ~600 B excerpt + frame = ~4 KB typical, well under the 8 KB target.
- [x] **Early-exit guards**: Empty prompt, empty keywords, empty candidate list, and empty hit list each short-circuit to `exit 0` before expensive work.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Shellcheck | Static | `shellcheck scripts/vault-rag.sh` — exit 0 |
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

<!-- Added by issue #5 — embedding-based retrieval swap -->

## Embedding Backend (Issue #5)

### Overview

Issue #5 layers an **embedding-based retrieval path** onto the existing keyword design without changing `hooks/hooks.json`. The product principle being exercised is **"one-script swaps"** (`steering/product.md` → Product Principles) — retrieval backends are swappable at the script layer, not the hook-wiring layer. The swap is opt-in via a new `rag.backend` config key; `"keyword"` remains the default so v0.1 users see no behavior change.

The approach refactors `scripts/vault-rag.sh` into a **thin dispatcher** that reads `rag.backend` from config and delegates to one of two backend scripts. The existing keyword logic is extracted verbatim into `scripts/vault-rag-keyword.sh`; the new embedding logic lives in `scripts/vault-rag-embedding.sh`. Any failure in the embedding path silently falls through to the keyword path, preserving the "never blocks the user" invariant.

### Backend Choice: ollama + nomic-embed-text

Of the three backends the issue allowed (bundled local model, ollama-backed, SaaS API), **ollama** is selected:

- **Bundled local model** requires an ONNX runtime or similar, a model file shipped in the plugin, and platform-specific binaries — incompatible with the "plain Bash + jq" distribution shape.
- **SaaS API** (OpenAI etc.) violates the local-first Product Principle. It would require network auth management and leak prompt-derived queries.
- **ollama** runs locally, exposes a stable HTTP API (`POST /api/embeddings`), is well-established on both macOS and Linux, requires no code bundled into the plugin, and is opt-in by construction — if the user hasn't installed and started it, the plugin falls through to keyword retrieval with no harm.

Default model: **`nomic-embed-text`** (768 dims, small, fast to embed, popular default). Both endpoint (`rag.embedding.endpoint`, default `http://127.0.0.1:11434`) and model (`rag.embedding.model`) are configurable so users with existing ollama installs can pick their own.

### Component Diagram (embedding path)

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code session: user hits Enter on a prompt               │
└─────────────────────────┬───────────────────────────────────────┘
                          │ UserPromptSubmit event
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  hooks/hooks.json  (UNCHANGED — the "one-script swap" guarantee)│
│   UserPromptSubmit[0].hooks[0].command =                        │
│     ${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │ stdin: { "prompt": "…" }
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/vault-rag.sh  (NEW role: thin dispatcher)              │
│   1. guards identical to v0.1 (jq, config, rag.enabled)         │
│   2. read rag.backend (default "keyword")                       │
│   3. switch:                                                    │
│       "keyword"   → exec vault-rag-keyword.sh                   │
│       "embedding" → try vault-rag-embedding.sh                  │
│                     │                                           │
│                     └── on any error → exec keyword + log       │
│       other        → log warning → exec keyword                 │
└─────────────┬─────────────────────────────────────┬─────────────┘
              │                                     │
              ▼                                     ▼
┌─────────────────────────┐              ┌──────────────────────────┐
│ vault-rag-keyword.sh    │              │ vault-rag-embedding.sh   │
│ (v0.1 logic extracted   │              │ 1. validate: curl,       │
│  unchanged)             │              │    ollama reachable,     │
│                         │              │    model present,        │
│                         │              │    index file present    │
│                         │              │ 2. POST /api/embeddings  │
│                         │              │    with prompt → query   │
│                         │              │    vector               │
│                         │              │ 3. stream index JSONL;   │
│                         │              │    cosine-score each row │
│                         │              │    via awk helper        │
│                         │              │ 4. sort -rn; head -n K   │
│                         │              │ 5. emit <vault-context>  │
│                         │              │    with excerpt via      │
│                         │              │    shared formatter      │
│                         │              │ On ANY failure →         │
│                         │              │    exec keyword path     │
└─────────────────────────┘              └──────────────────────────┘
```

### Data Flow (embedding path)

```
Prompt text (stdin JSON .prompt)
   │
   ▼
curl -sS --max-time 5 -X POST http://127.0.0.1:11434/api/embeddings \
     -H 'content-type: application/json' \
     -d '{"model":"nomic-embed-text","prompt":"<prompt>"}'
   │   (prompt sent in the JSON body only — never in an argv string)
   ▼
jq -r '.embedding[]' → QUERY_VEC (newline-separated floats, 768 values)
   │
   ▼
Stream ~/.claude/obsidian-memory/index/embeddings.jsonl:
  for each line {"path","embedding":[...],"mtime"}:
      awk computes dot(QUERY_VEC, embedding) / (||QUERY_VEC|| * ||embedding||)
      emits "<score>\t<abs-path>"
   │
   ▼
sort -rn -k1,1 | head -n $TOP_K → TOP  (default 5; configurable via rag.top_k)
   │
   ▼
Shared excerpt formatter (same Markdown frame as keyword path):
  printf '<vault-context source="obsidian" backend="embedding" model="nomic-embed-text">\n'
  per (score, path): emit "### <rel>  (score: <s>)" + fenced excerpt (first ~600 B of the note)
  printf '</vault-context>\n'
```

### Index Format and Location

The index is a **single JSONL file** at `~/.claude/obsidian-memory/index/embeddings.jsonl`. Plain text keeps the local-first, inspectable principle intact — the user can `cat`, `grep`, or `wc -l` the index from a shell; no SQLite, no custom binary format.

One line per indexed note:

```json
{"path":"<abs-path>","rel":"<path-relative-to-vault>","embedding":[f1,f2,…,f768],"mtime":<unix-ts>,"model":"nomic-embed-text","dim":768}
```

Exclusions at index time match the v0.1 keyword path exactly: `claude-memory/projects/**`, `.obsidian/**`, `.trash/**`, and the same `*.md` glob. This guarantees AC5/AC6 feedback-loop protection carries across both backends.

A companion file `~/.claude/obsidian-memory/index/embeddings.meta.json` stores build metadata:

```json
{"built_at": 1745270400, "vault_path": "...", "note_count": 1234, "model": "nomic-embed-text", "dim": 768}
```

`/obsidian-memory:doctor` reads this file to surface index freshness.

### Async Rebuild Decision

Per AC15, the hook **never rebuilds the index synchronously**. The chosen implementation uses the existing index **as-is** on every invocation — no auto-refresh, no background spawn, no mtime comparison on the hot path. This is the minimal, latency-safe choice: indexing is exclusively driven by the user running `/obsidian-memory:reindex`. A future enhancement may add `rag.auto_reindex = "detached"` to fork a detached rebuild when staleness is detected; that is explicitly Out of Scope here.

### /obsidian-memory:reindex Skill

A new user-invocable skill at `skills/reindex/SKILL.md` orchestrates index construction. It is **not** a hook — it runs only on demand.

Behavior:

1. Read `~/.claude/obsidian-memory/config.json`; abort with a user-visible error if embedding backend is not configured or ollama is unreachable. Reindex is the one place a visible error is acceptable because the user invoked it deliberately.
2. Enumerate notes under `$VAULT` with the same exclusion rules as the RAG hook.
3. For each note: read contents, truncate to a model-appropriate size (first ~8 KB), POST to `/api/embeddings`, collect the vector.
4. Write `embeddings.jsonl` atomically: build a temp file under `~/.claude/obsidian-memory/index/`, `mv` into place.
5. Write `embeddings.meta.json` with the new timestamp.
6. Print progress to stdout (N/M notes); print a final summary line.

Idempotent: re-running the skill rebuilds the index from scratch — simpler than incremental updates, and for ~1k-note vaults the wall time is dominated by ollama, not file I/O.

### Dispatcher Contract (`vault-rag.sh` after amendment)

The dispatcher preserves every guard and exit-0 invariant from v0.1. Pseudocode:

```bash
# … existing v0.1 guards: jq, config, rag.enabled, vault dir …

backend="$(jq -r '.rag.backend // "keyword"' "$CONFIG" 2>/dev/null)"
case "$backend" in
  keyword)   exec "$PLUGIN_ROOT/scripts/vault-rag-keyword.sh"   ;;  # stdin inherited
  embedding)
    # try embedding; on any failure, exec keyword
    if "$PLUGIN_ROOT/scripts/vault-rag-embedding.sh" < "$PAYLOAD_TMP"; then
      exit 0
    fi
    log_err "embedding backend failed; falling back to keyword"
    exec "$PLUGIN_ROOT/scripts/vault-rag-keyword.sh" < "$PAYLOAD_TMP"
    ;;
  *)
    log_err "unknown rag.backend=$backend; using keyword"
    exec "$PLUGIN_ROOT/scripts/vault-rag-keyword.sh" < "$PAYLOAD_TMP"
    ;;
esac
```

Stdin has to be replayed because both backends need the original JSON payload. The dispatcher tees the payload to a per-invocation `mktemp` file and cleans it via the EXIT trap — identical scratch-file pattern to the existing implementation.

### Cosine Similarity in awk

The ranking kernel is a small awk program fed with the query vector as an env var and the index JSONL on stdin. Skeleton:

```awk
# QVEC env var is space-separated floats
BEGIN { n = split(ENVIRON["QVEC"], q, " "); for (i=1;i<=n;i++) qnorm += q[i]*q[i]; qnorm = sqrt(qnorm) }
{
  # input line: <rel>\t<f1> <f2> … <fN>
  split($2, v, " ")
  dot = 0; norm = 0
  for (i=1;i<=n;i++) { dot += q[i]*v[i]; norm += v[i]*v[i] }
  score = (qnorm > 0 && norm > 0) ? dot / (qnorm * sqrt(norm)) : 0
  printf "%.6f\t%s\n", score, $1
}
```

The embedding-path script preprocesses each JSONL line into `<rel>\t<space-separated-floats>` via `jq -r` before feeding awk. All heavy numeric work is in awk, which is on every target platform (macOS default + Linux), so no extra runtime dependency.

Performance ceiling: for a 1k-note × 768-dim vault, this is ~768 × 1000 = ~768k multiplies — well under 100 ms in awk. The dominant cost is the single ollama round-trip for the query (~30–80 ms on a warm daemon). The hot-path p95 target of <300 ms from `tech.md` stays comfortably in range for vaults up to ~5k notes before revisiting. Beyond that, a sqlite-vec or hnswlib swap is a future issue.

### Fallback Protocol (Silent Failure)

Every failure mode in the embedding path is mapped to one behavior: **exec the keyword backend**. The complete list:

| Failure mode | Detection | Action |
|---|---|---|
| `curl` not on PATH | `command -v curl` | exec keyword; stderr: `"curl missing"` |
| ollama unreachable | `curl` non-2xx or timeout | exec keyword; stderr: `"ollama unreachable"` |
| Model not pulled | HTTP response body has no `.embedding` | exec keyword; stderr: `"model missing"` |
| Index file missing | `test -f embeddings.jsonl` fails | exec keyword; stderr: `"index missing — run /obsidian-memory:reindex"` |
| Index file empty / corrupt | Zero rows or `jq` parse failure | exec keyword; stderr: `"index corrupt"` |
| awk ranking produced no results | `wc -l` on ranked output = 0 | exec keyword (same as "no matches") |

The stderr line fires **once** per invocation and goes to Claude Code's hook operator log, never to the session UI (per `tech.md` Security / silent-failure rules).

### `hooks/hooks.json` — Explicitly Unchanged

This is the **load-bearing invariant** of the issue. The existing declaration:

```json
{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh"}
```

is the single source of truth for what Claude Code fires on `UserPromptSubmit`. The embedding swap replaces the *contents* of `vault-rag.sh` with a dispatcher and adds sibling scripts. `hooks.json` stays byte-identical. This guarantees no user action is required to adopt (or ignore) embedding retrieval — the v0.1 config path through the dispatcher produces v0.1 output exactly.

### Alternatives Considered (Issue #5)

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **F: sqlite-vec extension** | Store embeddings in `~/.claude/obsidian-memory/index.db` with the `sqlite-vec` extension | Proper ANN; scales to 100k+ notes; ACID persistence | Requires the extension to be available; violates "plain text > databases" principle; more complex ops (migrations, corruption recovery) | Rejected — plain JSONL is sufficient for target vault sizes |
| **G: hnswlib via a Python helper** | Ship a Python dependency and use hnswlib for fast ANN | Best-in-class ranking performance | Adds a Python dep the plugin otherwise doesn't need; platform-specific wheel issues; violates "Bash + jq" distribution | Rejected |
| **H: OpenAI embeddings SaaS** | Call `POST https://api.openai.com/v1/embeddings` | High-quality embeddings; no local install | Violates local-first; requires API key management; per-prompt network latency | Rejected — fails the Product Principle |
| **I: Bundled ONNX model + runtime** | Ship a small `all-MiniLM-L6-v2` ONNX file and call `onnxruntime` | Fully self-contained; no user install step | Platform-specific binaries; plugin size balloons; "one-script swap" breaks down into "install a runtime first" | Rejected |
| **J: ollama + nomic-embed-text + JSONL index** | Current design | Local-first; opt-in; inspectable; zero plugin-bundled binaries; awk-only ranking | Opt-in friction — user must `ollama pull nomic-embed-text`; 100s of ms for huge vaults (still under p95 target for 1k-note target) | **Selected** |
| **K: Auto-refresh index on staleness** | Detect stale index on hot path, fork detached rebuild | No manual reindex needed | Complicates hot path; a half-built index during a rebuild races with concurrent reads | Rejected for this issue — revisit after AC17 regression is locked in |

### Security Considerations (Issue #5)

- **Prompt never enters an argv**. The prompt is sent to ollama as the `prompt` field of a JSON body via `curl --data @-`, read from stdin; it is never concatenated into a shell string. This preserves the FR11 / AC12 safety model.
- **ollama is local-only by default** (`127.0.0.1:11434`). The configured endpoint is validated at embedding time — any non-loopback endpoint is permitted (for users running ollama on a LAN server) but a one-time stderr warning is emitted so operators notice. No credentials are ever sent.
- **Index contents are derived from the user's own vault** — the `<vault-context>` block under the embedding path reveals the same classes of content the keyword path already does. No new data egress.
- **Model response is parsed with `jq -r '.embedding[]'`** — a malformed response falls through `jq`'s exit code into the fallback branch; no unsafe parsing of model output.

### Performance Considerations (Issue #5)

- **Hot-path cost is dominated by one ollama round-trip** (~30–80 ms on a warm daemon; cold-start the model is ~300–500 ms, which is acceptable under the "first prompt after reboot" case and uncommon during normal use).
- **Awk cosine kernel is cheap**: 1k notes × 768 dims × ~3 FLOPs per dim ≈ 2.3M ops, well under 50 ms.
- **Index size**: ~25 KB per note at 768 dims (ASCII floats), so a 1k-note vault is ~25 MB on disk. Acceptable — the user's vault is usually orders of magnitude larger.
- **No network calls** unless `rag.backend = "embedding"` AND ollama is the configured endpoint AND the hook is actually firing. In the default (`keyword`) state, the embedding path is never touched.
- **Fallback cost is a `curl` timeout**. The `--max-time 5` ceiling caps the worst case at ~5 s when ollama is wedged or unreachable — above the p95 target but survivable as a one-time event; subsequent invocations can either be reconfigured to `keyword` or the user starts ollama.

### Testing Strategy (Issue #5)

| Layer | Type | Coverage |
|-------|------|----------|
| Shellcheck | Static | `scripts/vault-rag-keyword.sh`, `scripts/vault-rag-embedding.sh`, `scripts/vault-reindex.sh` — exit 0 |
| Unit (awk kernel) | bats | Feed known query + known index rows, assert cosine ordering |
| Integration — stub ollama | bats | Seed a scratch HTTP server (netcat-based) returning a canned `/api/embeddings` response; assert semantic ranking |
| Integration — fallback | bats | Point `rag.embedding.endpoint` at a closed port; assert keyword-path output is produced and stderr logs the fallback reason |
| Integration — reindex | bats | Run `/obsidian-memory:reindex` against a scratch vault with stub ollama; assert `embeddings.jsonl` + `embeddings.meta.json` exist with expected row count |
| BDD | cucumber-shell | AC13–AC18 as scenarios; Background seeds stub-ollama |
| Regression | BDD | All 12 existing scenarios run unchanged against the dispatcher when `rag.backend = "keyword"` (AC17) |

Real ollama is NOT required in CI. The stub-ollama helper is a ~30-line Bash function that `nc -l`-s a port and returns a canned JSON response derived from the request prompt's word count (so the test can deterministically assert ranking). An opt-in `TESTS_REQUIRE_REAL_OLLAMA=1` env var runs a smoke test against the real daemon for local verification.

### Risks & Mitigations (Issue #5)

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| User enables embedding but never runs reindex → every prompt falls back silently with no guidance | High | Medium | `/obsidian-memory:doctor` surfaces "index missing" as an informational line; the stderr log message names the reindex skill |
| ollama model upgrade changes embedding dimensions → old index no longer compatible | Medium | Low | `embeddings.meta.json` stores `dim` and `model`; embedding script validates these match at query time and falls back if not |
| Concurrent prompts during a `/obsidian-memory:reindex` run race with partial writes | Low | Low | Reindex writes to a temp file and `mv`s atomically; concurrent reads see either the old or new index, never a half-written one |
| Ollama daemon reachable on loopback but hijacked by a different model → wrong embeddings | Very Low | Low | Dimension check catches this; optional future work could add a `sha256` of the model name/version to meta |
| Vault contains binary-ish or huge notes that confuse the model | Low | Low | Reindex truncates to first ~8 KB per note; fencing in the hot path is handled by the shared excerpt formatter |
| Embedding path latency exceeds 300 ms on a cold ollama | Medium | Low | Cold-start is a one-time event; fallback still fires if `curl --max-time 5` is breached; document "ollama warmup" in the reindex skill |

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #10 | 2026-04-19 | Initial baseline design — documents v0.1.0 shipped behavior |
| #5 | 2026-04-21 | Added embedding-backend design: ollama + nomic-embed-text dispatcher swap, JSONL index at `~/.claude/obsidian-memory/index/`, awk-based cosine ranking, silent fallback protocol, reindex skill, and the load-bearing invariant that `hooks/hooks.json` is unchanged |

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
