# Tasks: RAG prompt injection hook

**Issues**: #10
**Date**: 2026-04-19
**Status**: Complete (baseline — tasks describe work already shipped in v0.1.0)
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
| **Total** | **8** | |

Retroactive task breakdown. Implementation artefacts live in `scripts/vault-rag.sh` and `hooks/hooks.json`; testing phase is blocked on #1.

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

## Dependency Graph

```
T001 ──▶ T002 ──▶ T003 ──▶ T004 ──▶ T005
                                      │
                                      ▼
                                     T006 (interop with feature-vault-setup)

T007 (independent)

T008 ─── depends on T007 and #1
T009 ─── depends on T008 and #1
```

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #10 | 2026-04-19 | Initial baseline task breakdown — documents v0.1.0 shipped implementation; testing phase deferred to #1 |

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
