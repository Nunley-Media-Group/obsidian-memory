# Tasks: Manual distill-session skill

**Issues**: #12
**Date**: 2026-04-19
**Status**: Complete (baseline — tasks describe work already shipped in v0.1.0)
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [x] |
| Backend | 0 | N/A (delegates to hook) |
| Frontend | 0 | N/A |
| Integration | 3 | [x] |
| Testing | 3 | [ ] (deferred to #1 bats-core harness) |
| **Total** | **7** | |

Retroactive task breakdown. Implementation artefact lives in `plugins/obsidian-memory/skills/distill-session/SKILL.md`.

---

## Phase 1: Setup

### T001: SKILL.md frontmatter + skill-runtime contract

**File(s)**: `plugins/obsidian-memory/skills/distill-session/SKILL.md`
**Type**: Create
**Depends**: None
**Acceptance**:
- [x] Frontmatter declares `name: distill-session`, `description`, `argument-hint:` (empty), `allowed-tools: Bash, Read`, `model: sonnet`, `effort: low`
- [x] Description covers keyword triggers ("distill this session", "checkpoint", "save this session to my vault", invocation command)
- [x] Skill loads under the `obsidian-memory:` namespace

---

## Phase 4: Integration

### T002: Prereq check + transcript discovery

**File(s)**: `plugins/obsidian-memory/skills/distill-session/SKILL.md` (Workflow sections 1–2)
**Type**: Create
**Depends**: T001
**Acceptance**:
- [x] Step "Locate the newest transcript" uses `find ~/.claude/projects -type f -name '*.jsonl' -print0 | xargs -0 ls -1t | head -n 1` (FR2)
- [x] Empty result → report "no Claude Code transcripts found" and stop (FR3, AC2)
- [x] Prerequisites section declares `jq` + `claude` + config must exist; skill reports and stops if missing (FR1, AC3)

### T003: Payload construction + hook invocation

**File(s)**: `plugins/obsidian-memory/skills/distill-session/SKILL.md` (Workflow section 3)
**Type**: Create
**Depends**: T002
**Acceptance**:
- [x] `SESSION_ID` derived from `basename "$TRANSCRIPT" .jsonl` (FR4)
- [x] `CWD` derived from `pwd`; `REASON` hard-coded to `"manual"` (FR4, AC5)
- [x] Payload synthesized via `jq -n --arg …` (FR5, security)
- [x] Piped into `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-distill.sh` (FR6)
- [x] Reuses `feature-session-distillation-hook` artefact unchanged (parity requirement)

### T004: Output location + reporting

**File(s)**: `plugins/obsidian-memory/skills/distill-session/SKILL.md` (Workflow sections 4–5)
**Type**: Create
**Depends**: T003
**Acceptance**:
- [x] Reads `vaultPath` from config (FR7)
- [x] Computes slug via same transform as the hook (`basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E …`) (FR7)
- [x] Locates newest `<slug>/*.md` via `ls -1t | head -n 1` (FR7)
- [x] Reports: transcript path, project slug, note path, real-vs-stub marker (FR8, AC7)

---

## Phase 5: BDD Testing (Required)

> Deferred until #1 lands the bats-core harness.

### T005: BDD feature file

**File(s)**: `specs/feature-manual-distill-skill/feature.gherkin`
**Type**: Create
**Depends**: None (authored alongside this spec)
**Acceptance**:
- [x] All 7 acceptance criteria are scenarios
- [x] Scenarios use Given/When/Then format
- [x] Valid Gherkin syntax

### T006: Parity integration tests

**File(s)**: `tests/integration/distill-session-skill.bats`, `tests/features/steps/distill-session.sh`
**Type**: Create
**Depends**: T005, issue #1
**Acceptance**:
- [ ] Happy-path test seeds a scratch transcript, invokes the skill, asserts hook output artefact (AC1)
- [ ] Failure-mode tests cover AC2 (no transcripts) and AC3 (missing deps)
- [ ] Idempotency test invokes skill twice and asserts two distinct timestamped files (AC4)
- [ ] Parity test: run skill vs. directly invoke `vault-distill.sh` with equivalent payload; diff resulting artefacts; must match except `end_reason` ("manual" vs. provided reason) — success-metric verification
- [ ] Passes `bats tests/integration` and `tests/run-bdd.sh`

### T007: Fallback-stub reporting test

**File(s)**: `tests/integration/distill-session-skill.bats` (continued)
**Type**: Create
**Depends**: T006, issue #1
**Acceptance**:
- [ ] Stub `claude` binary configured to return empty
- [ ] Invoke skill; assert report contains "fallback stub" marker (AC7)

---

## Dependency Graph

```
T001 ──▶ T002 ──▶ T003 ──▶ T004
                           │
                           ▼
                          (delegates to feature-session-distillation-hook's vault-distill.sh)

T005 (independent)

T006 ─── depends on T005 and #1
T007 ─── depends on T006 and #1
```

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #12 | 2026-04-19 | Initial baseline task breakdown — documents v0.1.0 shipped implementation; testing phase deferred to #1 |

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
