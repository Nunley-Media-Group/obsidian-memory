# Tasks: Session distillation hook

**Issues**: #11
**Date**: 2026-04-19
**Status**: Complete (baseline — tasks describe work already shipped in v0.1.0)
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [x] |
| Backend | 4 | [x] |
| Frontend | 0 | N/A |
| Integration | 1 | [x] |
| Testing | 3 | [ ] (deferred to #1 bats-core harness) |
| **Total** | **9** | |

Retroactive task breakdown. Implementation artefacts already exist in `plugins/obsidian-memory/scripts/vault-distill.sh` and `plugins/obsidian-memory/hooks/hooks.json`.

---

## Phase 1: Setup

### T001: Hook wiring

**File(s)**: `plugins/obsidian-memory/hooks/hooks.json`
**Type**: Create
**Depends**: None
**Acceptance**:
- [x] `SessionEnd[0].hooks[0]` is `{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-distill.sh" }`
- [x] JSON is valid per `jq empty`
- [x] Claude Code registers the hook on plugin load
- [x] `SessionEnd` wiring coexists with `UserPromptSubmit` wiring (see feature-rag-prompt-injection T001)

---

## Phase 2: Backend Implementation

### T002: Prelude, safety traps, and input guards

**File(s)**: `plugins/obsidian-memory/scripts/vault-distill.sh` (lines ~1–40)
**Type**: Create
**Depends**: T001
**Acceptance**:
- [x] Shebang `#!/usr/bin/env bash`; `set -u`; `trap 'exit 0' ERR`
- [x] Deps: `jq`, `claude` (both → exit 0 if missing) — AC7, AC8
- [x] Config: read `~/.claude/obsidian-memory/config.json`; extract `vaultPath`, `(distill.enabled != false)` — AC9, AC6
- [x] Vault directory exists check → exit 0 if not — AC9 companion
- [x] stdin JSON extraction for `transcript_path`, `cwd`, `session_id`, `reason`; defaults for empty values — FR1
- [x] Transcript readability + size ≥ 2,000 bytes check — AC2, AC10

### T003: Project slug derivation

**File(s)**: `plugins/obsidian-memory/scripts/vault-distill.sh` (~line 43)
**Type**: Create
**Depends**: T002
**Acceptance**:
- [x] `SLUG="$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"` (FR4, AC11)
- [x] Falls back to `unknown` if the transform yields an empty string
- [x] Resulting slug satisfies `^[a-z0-9-]+$`

### T004: Transcript extraction + distillation subprocess

**File(s)**: `plugins/obsidian-memory/scripts/vault-distill.sh` (~lines 45–98)
**Type**: Create
**Depends**: T003
**Acceptance**:
- [x] `jq` filter selects `user|assistant` messages
- [x] Handles both `content: [parts]` and `content: "string"` shapes (AC14)
- [x] Renders `tool_use` parts as `[tool_use: <name>]` and `tool_result` parts as stringified content (AC14)
- [x] Output piped through `head -c 204800` (AC13)
- [x] Empty extracted conversation → exit 0
- [x] Distillation prompt is the fixed template (FR6 schema)
- [x] Subprocess: `CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null` (FR6, AC12)

### T005: Note file + Index.md updater

**File(s)**: `plugins/obsidian-memory/scripts/vault-distill.sh` (~lines 100–157)
**Type**: Create
**Depends**: T004
**Acceptance**:
- [x] Timestamps derived via `date -u +...` — UTC
- [x] `OUT_DIR = $VAULT/claude-memory/sessions/$SLUG`; `mkdir -p` guarded by `|| exit 0`
- [x] `OUT_FILE = $OUT_DIR/$NOW_STAMP.md` written with YAML frontmatter (date, time, session_id, project, cwd, end_reason, source) + body (AC1)
- [x] Fallback stub body when `NOTE_BODY` is empty (AC3)
- [x] `Index.md` absent → create with header + helper paragraph + `## Sessions` + link line (AC4)
- [x] `Index.md` present with `^## Sessions\s*$` → `awk` inserts link line immediately after heading (AC1 ordering)
- [x] `Index.md` present without `## Sessions` heading → appends new heading + link line (AC5)
- [x] Final `exit 0`

---

## Phase 4: Integration

### T006: Config interop with feature-vault-setup

**File(s)**: (cross-spec verification)
**Type**: Verify
**Depends**: T001–T005, feature-vault-setup #9
**Acceptance**:
- [x] `/obsidian-memory:setup` creates `sessions/` parent dir the hook expects
- [x] `/obsidian-memory:setup` writes the same config schema (`distill.enabled`) the hook reads
- [x] `/obsidian-memory:setup` seeds `Index.md` compatible with the hook's `awk` inserter
- [x] Both specs cross-reference each other

---

## Phase 5: BDD Testing (Required)

> Deferred until #1 lands the bats-core harness.

### T007: BDD feature file

**File(s)**: `specs/feature-session-distillation-hook/feature.gherkin`
**Type**: Create
**Depends**: None (authored alongside this spec)
**Acceptance**:
- [x] All 14 acceptance criteria are scenarios
- [x] Scenarios use Given/When/Then format
- [x] Error + edge + security scenarios included
- [x] Valid Gherkin syntax

### T008: Step definitions + integration tests

**File(s)**: `tests/features/steps/vault-distill.sh`, `tests/integration/vault-distill.bats`
**Type**: Create
**Depends**: T007, issue #1
**Acceptance**:
- [ ] Stub `claude` binary driven by env var (`STUB_CLAUDE_MODE=normal|empty|env_echo`)
- [ ] Fixture JSONL transcripts: trivial (<2KB), normal, array-content, string-content, mixed, >200 KB
- [ ] All filesystem state under `$BATS_TEST_TMPDIR`
- [ ] Asserts slug sanitization against adversarial `cwd` values (AC11)
- [ ] Asserts Index.md newest-first ordering after 5 consecutive invocations
- [ ] Passes `bats tests/integration` and `tests/run-bdd.sh`

### T009: Safety property tests

**File(s)**: `tests/integration/vault-distill-safety.bats`
**Type**: Create
**Depends**: T008, issue #1
**Acceptance**:
- [ ] Property: for every `cwd` in an adversarial fixture set, the resulting write is under `$VAULT/claude-memory/sessions/` (AC11 + success metric)
- [ ] Property: the hook exits 0 for every documented failure mode (AC2, AC6, AC7, AC8, AC9, AC10)

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
| #11 | 2026-04-19 | Initial baseline task breakdown — documents v0.1.0 shipped implementation; testing phase deferred to #1 |

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
