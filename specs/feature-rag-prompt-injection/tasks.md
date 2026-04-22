# Tasks: RAG prompt injection hook

**Issues**: #10, #5
**Date**: 2026-04-21
**Status**: Amended
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [x] |
| Backend | 3 | [x] |
| Frontend | 0 | N/A |
| Integration | 1 | [x] |
| Testing | 3 | [ ] (deferred to #1 bats-core harness) |
| Phase 6: Embedding Retrieval Swap (Issue #5) | 11 | [ ] |
| **Total** | **19** | |

Retroactive task breakdown for the v0.1 baseline. Phase 6 (added by issue #5) swaps keyword retrieval for an opt-in embedding path via ollama without changing `hooks/hooks.json`.

---

## Phase 1: Setup

### T001: Hook wiring

**File(s)**: `hooks/hooks.json`
**Type**: Create
**Depends**: None
**Acceptance**:
- [x] `UserPromptSubmit[0].hooks[0]` is `{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-rag.sh" }`
- [x] JSON is valid per `jq empty`
- [x] Claude Code registers the hook on plugin load

---

## Phase 2: Backend Implementation

### T002: Script prelude + safety traps + config guard

**File(s)**: `scripts/vault-rag.sh` (lines ~1–23)
**Type**: Create
**Depends**: T001
**Acceptance**:
- [x] Shebang `#!/usr/bin/env bash` (per `tech.md`)
- [x] `set -u` and `trap 'exit 0' ERR` at top (no `set -e`)
- [x] Guards: missing `jq` → exit 0 (AC7); missing/unreadable config → exit 0 (AC8); `rag.enabled=false` → exit 0 (AC4); missing vault directory → exit 0
- [x] `vaultPath` extracted via `jq -r '.vaultPath // empty'`

### T003: Prompt tokenizer + keyword filter

**File(s)**: `scripts/vault-rag.sh` (lines ~25–47)
**Type**: Create
**Depends**: T002
**Acceptance**:
- [x] Payload read from stdin; `.prompt` extracted via `jq -r` (FR1)
- [x] Empty payload or empty prompt → exit 0
- [x] Tokenization: `tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n'` (FR4)
- [x] `awk` with stopword set, dedupe `seen[$0]++`, length filter `>=4`, cap at 6 (FR4, AC9, AC10)
- [x] Alternation regex built via `paste -sd '|'` — never composed with shell metacharacters (FR5, FR11, AC12)
- [x] Empty keyword list → exit 0 (AC9)

### T004: File enumeration, scoring, and ranking

**File(s)**: `scripts/vault-rag.sh` (lines ~49–91)
**Type**: Create
**Depends**: T003
**Acceptance**:
- [x] `rg -c` single-pass fast-path with `--glob '*.md'`, `'!.obsidian/**'`, `'!.trash/**'` (FR6, AC5, AC6)
- [x] POSIX fallback: `find -prune` over `.obsidian` and `.trash` piped via `xargs -0 grep -c -i -E` (FR6, AC3)
- [x] Single-pass scoring emits `N:path`; `awk` normalizes to `hits\tpath` (FR7)
- [x] Sorted by descending hit count; `head -n 5` (FR8, AC11)
- [x] Temp files cleaned via `trap 'rm -f … ; exit 0' EXIT`
- [x] Empty candidate list or empty hit list → exit 0 (AC2)

### T005: Output formatter

**File(s)**: `scripts/vault-rag.sh` (lines ~93–107)
**Type**: Create
**Depends**: T004
**Acceptance**:
- [x] Opens with `<vault-context source="obsidian" keywords="$KW_ATTR">` (FR9, AC1)
- [x] Per-file: `### <rel-path>  (hits: <N>)` header + triple-backtick fenced excerpt (AC11)
- [x] Excerpt: `grep -n -i -E -B 2 -A 8 -m 1 -e REGEX | head -c 600` (AC11)
- [x] Closes with `</vault-context>` followed by `exit 0`

---

## Phase 4: Integration

### T006: Config interop with feature-vault-setup

**File(s)**: (no new file; wiring check)
**Type**: Verify
**Depends**: T001–T005, feature-vault-setup #9
**Acceptance**:
- [x] `/obsidian-memory:setup` writes the config schema the hook reads (`vaultPath`, `rag.enabled`)
- [x] `setup` step 6 smoke-tests this hook with a synthetic payload
- [x] Both specs cross-reference each other

---

## Phase 5: BDD Testing (Required)

> Deferred until #1 lands the bats-core harness.

### T007: BDD feature file

**File(s)**: `specs/feature-rag-prompt-injection/feature.gherkin`
**Type**: Create
**Depends**: None (authored alongside this spec)
**Acceptance**:
- [x] All 12 acceptance criteria are scenarios
- [x] Scenarios use Given/When/Then format
- [x] Error/edge/security cases included
- [x] Valid Gherkin syntax

### T008: Step definitions + integration tests

**File(s)**: `tests/features/steps/vault-rag.sh`, `tests/integration/vault-rag.bats`
**Type**: Create
**Depends**: T007, issue #1
**Acceptance**:
- [ ] Step definitions cover every Given/When/Then phrase used in the 12 scenarios
- [ ] All filesystem state under `$BATS_TEST_TMPDIR`
- [ ] Stubs `rg` path (unset `PATH`) to force the fallback in AC3
- [ ] Seeds a 1,000-note fixture vault for performance assertions
- [ ] Passes `bats tests/integration` and `tests/run-bdd.sh`

### T009: Performance benchmark

**File(s)**: `tests/integration/vault-rag-perf.bats`
**Type**: Create
**Depends**: T008, issue #1
**Acceptance**:
- [ ] Seeds 1,000-note vault, invokes hook 20× with varied prompts
- [ ] Asserts p95 wall time < 300 ms (NFR)
- [ ] Skippable via env var on slow CI runners

---

## Phase 6: Embedding Retrieval Swap — Issue #5

> Blocked by #1 (bats-core + cucumber-shell harness). AC17 (keyword-path preservation) cannot be proven without the harness, and the amendment will not land until the regression gate is in place.

### T010: Extract keyword logic into `scripts/vault-rag-keyword.sh`

**File(s)**: `scripts/vault-rag-keyword.sh` (new), `scripts/vault-rag.sh` (source of extraction)
**Type**: Refactor
**Depends**: T005, issue #1
**Acceptance**:
- [ ] New file `scripts/vault-rag-keyword.sh` contains the full v0.1 tokenizer + scoring + formatter logic, byte-for-byte equivalent in behavior to the v0.1 `vault-rag.sh`
- [ ] File has the standard hook prelude from `structure.md` (shebang, `set -u`, ERR trap `exit 0`)
- [ ] `shellcheck scripts/vault-rag-keyword.sh` exits 0
- [ ] All 12 existing BDD scenarios pass when the extracted script runs directly (temporarily point `hooks.json` at it during the refactor test; restored in T011)
- [ ] No behavior change vs v0.1 (AC17 regression)

### T011: Convert `scripts/vault-rag.sh` into a dispatcher

**File(s)**: `scripts/vault-rag.sh`
**Type**: Modify
**Depends**: T010
**Acceptance**:
- [ ] `hooks/hooks.json` is NOT modified (FR17 — load-bearing invariant)
- [ ] Dispatcher preserves the v0.1 guards (jq, config, `rag.enabled`, vault dir)
- [ ] Reads `rag.backend` via `jq -r '.rag.backend // "keyword"'`
- [ ] `"keyword"` branch execs `vault-rag-keyword.sh` with stdin replayed via a `mktemp` scratch file
- [ ] `"embedding"` branch execs `vault-rag-embedding.sh`; on non-zero exit, falls back to `vault-rag-keyword.sh` and logs a one-line stderr reason
- [ ] Unknown `rag.backend` values log a stderr warning and fall back to keyword
- [ ] Scratch payload file cleaned via `trap 'rm -f … ; exit 0' EXIT`
- [ ] `shellcheck` exits 0

### T012: Implement `scripts/vault-rag-embedding.sh`

**File(s)**: `scripts/vault-rag-embedding.sh` (new)
**Type**: Create
**Depends**: T011
**Acceptance**:
- [ ] Standard hook prelude (`set -u`, ERR trap, `exit 0` on every terminating path — EXCEPT the controlled fallback return non-zero that signals the dispatcher)
- [ ] Validates prerequisites in order: `curl` on PATH, ollama reachable via `curl -sS --max-time 5`, `embeddings.jsonl` exists, meta `dim` matches index rows
- [ ] Any failed check returns non-zero to the dispatcher with a one-line stderr reason — never exits non-zero at the hook boundary (dispatcher handles translation)
- [ ] POSTs the prompt via `curl --data @-` reading the JSON body from stdin; prompt is NEVER in an argv (FR11 carries forward)
- [ ] Parses response with `jq -r '.embedding[]'` → space-separated query vector
- [ ] Runs the awk cosine kernel from `design.md` against `embeddings.jsonl` with `QVEC` in env
- [ ] Sorts by descending score; head `$TOP_K` (from `rag.top_k // 5`, clamped `1..50`)
- [ ] Emits `<vault-context source="obsidian" backend="embedding" model="…">` via the shared excerpt formatter
- [ ] `shellcheck` exits 0

### T013: Implement `scripts/vault-reindex.sh`

**File(s)**: `scripts/vault-reindex.sh` (new)
**Type**: Create
**Depends**: T011
**Acceptance**:
- [ ] Reads config; fails loudly (stderr + exit non-zero) when embedding backend is misconfigured or ollama unreachable — this is the one place in the plugin where a user-visible error is correct, because the user invoked the skill deliberately
- [ ] Enumerates `*.md` under `$VAULT` with exclusions `.obsidian/**`, `.trash/**`, `claude-memory/projects/**` (same as keyword path)
- [ ] Per note: read up to first ~8 KB, POST to `/api/embeddings`, collect embedding vector
- [ ] Writes temp file under `~/.claude/obsidian-memory/index/`, then `mv` atomically to `embeddings.jsonl` (AC15 safety — concurrent reads never see a half-written index)
- [ ] Writes companion `embeddings.meta.json` with `built_at`, `vault_path`, `note_count`, `model`, `dim`
- [ ] Prints `N/M notes indexed` progress on stdout; final summary line
- [ ] Exit code 0 on full success; non-zero on configuration or daemon failure (user-initiated, so surfacing is correct)
- [ ] `shellcheck` exits 0

### T014: Add `/obsidian-memory:reindex` skill

**File(s)**: `skills/reindex/SKILL.md` (new)
**Type**: Create
**Depends**: T013
**Acceptance**:
- [ ] Follows the skill template from `structure.md`: frontmatter (`name`, `description`, `version`), "When to Use", "When NOT to Use", "Invocation", "Behavior", "Idempotency", "Error handling"
- [ ] Invocation: `/obsidian-memory:reindex` (no args in v1; `--model <name>` and `--endpoint <url>` are documented as optional overrides)
- [ ] Behavior section delegates execution to `scripts/vault-reindex.sh`
- [ ] Idempotency: explicitly safe to re-run; rebuilds from scratch each time
- [ ] Error handling: documents each failure mode (ollama missing, model missing, vault missing) and the user-visible error

### T015: Add `rag.backend`, `rag.top_k`, `rag.embedding.*` config keys to `/obsidian-memory:setup`

**File(s)**: `skills/setup/SKILL.md`, `scripts/_common.sh` (if shared helpers exist)
**Type**: Modify
**Depends**: T011
**Acceptance**:
- [ ] `/obsidian-memory:setup` writes `rag.backend: "keyword"` by default when initializing a new config (preserves v0.1 behavior on upgrade)
- [ ] Existing configs lacking these keys are read as if the defaults were present — no migration required (FR13 → "default preserves v0.1")
- [ ] Setup documents the new keys in its SKILL.md "Configuration" section
- [ ] Setup does NOT install ollama or pull the model — documents the prerequisite only

### T016: Update `/obsidian-memory:doctor` with embedding-backend health check

**File(s)**: `skills/doctor/SKILL.md`, `scripts/vault-doctor.sh`
**Type**: Modify
**Depends**: T011, issue #2
**Acceptance**:
- [ ] Doctor reports `rag.backend` value (informational)
- [ ] When backend is `"embedding"`: reports ollama reachability at the configured endpoint, presence of the configured model in `ollama list`, path + mtime of `embeddings.jsonl`, and the `note_count` from `embeddings.meta.json`
- [ ] Every embedding-related check is **informational** — it flags "not ready" warnings but never fails the doctor exit code (FR19 — "non-failing")
- [ ] When backend is `"keyword"`: doctor makes no ollama call and no index-file read

### T017: Update `steering/tech.md` Technology Stack with ollama row

**File(s)**: `steering/tech.md`
**Type**: Modify
**Depends**: (independent of other T01x, can land first)
**Acceptance**:
- [ ] Technology Stack table gains a row: `ollama` with version `"any; opt-in for embedding backend"` and install command `"brew install ollama && ollama pull nomic-embed-text"` (Linux install instruction in a note)
- [ ] External Services section notes: "ollama remains local; the plugin never contacts a SaaS endpoint"
- [ ] Coding Standards retains the "pass via stdin or `--` separators" rule — amended to include the `curl --data @-` pattern as the canonical form for JSON bodies

### T018: BDD scenarios for AC13–AC18

**File(s)**: `specs/feature-rag-prompt-injection/feature.gherkin`
**Type**: Modify (append scenarios)
**Depends**: (authored alongside this spec — T007 pattern)
**Acceptance**:
- [ ] One scenario per new AC (AC13–AC18); existing 12 scenarios untouched
- [ ] Scenarios for embedding-backend behavior tagged `# Added by issue #5`
- [ ] Valid Gherkin syntax; `tests/run-bdd.sh` still parses

### T019: Step definitions for the embedding scenarios

**File(s)**: `tests/features/steps/vault-rag-embedding.sh` (new)
**Type**: Create
**Depends**: T018, T011–T014, issue #1
**Acceptance**:
- [ ] Step definitions cover every Given/When/Then phrase introduced in T018
- [ ] Provides a stub-ollama helper: spawns `nc -l` (or a minimal python3 `-c` one-liner if `nc` flavor varies) on a random port in `$BATS_TEST_TMPDIR`; returns a canned `/api/embeddings` response whose vector is deterministically derived from the request prompt
- [ ] Supports pointing the helper at a closed port to exercise the fallback path (AC14)
- [ ] Seeds a scratch `embeddings.jsonl` with known vectors for deterministic ranking assertions (AC13)
- [ ] `tests/run-bdd.sh` passes with the new scenarios

### T020: Integration tests — dispatcher, fallback, reindex

**File(s)**: `tests/integration/vault-rag-dispatcher.bats` (new), `tests/integration/vault-rag-embedding-fallback.bats` (new), `tests/integration/vault-reindex.bats` (new)
**Type**: Create
**Depends**: T019, issue #1
**Acceptance**:
- [ ] `vault-rag-dispatcher.bats` confirms AC17: every v0.1 BDD scenario produces identical stdout when `rag.backend = "keyword"` through the new dispatcher
- [ ] `vault-rag-embedding-fallback.bats` confirms AC14: setting `rag.backend = "embedding"` with a closed endpoint produces the keyword-path output and a single stderr line
- [ ] `vault-reindex.bats` confirms AC16: after `/obsidian-memory:reindex` against a seeded vault, `embeddings.jsonl` and `embeddings.meta.json` exist at `~/.claude/obsidian-memory/index/` with the expected row count
- [ ] All tests run entirely under `$BATS_TEST_TMPDIR` with scratch `$HOME` and scratch vault; no real `~/.claude` or real ollama required
- [ ] `bats tests/integration` exits 0

---

## Dependency Graph

```
T001 ──▶ T002 ──▶ T003 ──▶ T004 ──▶ T005
                                      │
                                      ▼
                                     T006 (interop with feature-vault-setup)

T007 (independent)

T008 ─── depends on T007 and #1
T009 ─── depends on T008 and #1

--- Phase 6 (Issue #5) ---

T017 (tech.md — independent, can land first)
T018 (gherkin — independent)

T010 ──▶ T011 ──┬─▶ T012 ──┐
                ├─▶ T013 ──▶ T014 (reindex skill)
                ├─▶ T015 (setup config keys)
                └─▶ T016 (doctor health)

T012 ──▶ T019 ──▶ T020
T013 ──▶ T019

All Phase 6 tasks are blocked by #1 (bats-core harness).
```

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #10 | 2026-04-19 | Initial baseline task breakdown — documents v0.1.0 shipped implementation; testing phase deferred to #1 |
| #5 | 2026-04-21 | Added Phase 6: extract keyword logic (T010), convert `vault-rag.sh` into a dispatcher (T011), implement embedding backend (T012) + reindex (T013) + reindex skill (T014), wire config into setup (T015) and doctor (T016), update `steering/tech.md` (T017), and add BDD + integration coverage (T018–T020). All Phase 6 tasks blocked by #1. |

---

## Validation Checklist

- [x] Each task has single responsibility
- [x] Dependencies are correctly mapped
- [x] Tasks can be completed independently (given dependencies)
- [x] Acceptance criteria are verifiable
- [x] File paths reference actual project structure (per `structure.md`)
- [x] Test tasks are included for each layer (deferred blocker documented)
- [x] No circular dependencies
- [x] Tasks are in logical execution order
