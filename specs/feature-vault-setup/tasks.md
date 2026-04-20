# Tasks: Vault setup skill

**Issues**: #9
**Date**: 2026-04-19
**Status**: Complete (baseline — tasks describe work already shipped in v0.1.0)
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [x] |
| Backend | 0 | N/A |
| Frontend | 0 | N/A |
| Integration | 2 | [x] |
| Testing | 3 | [ ] (deferred to #1 bats-core harness) |
| **Total** | **6** | |

This is a **retroactive** task breakdown. The implementation artefacts already exist in `skills/setup/SKILL.md`; the testing phase is not yet executable because the bats harness itself is tracked separately in #1.

---

## Phase 1: Setup

### T001: SKILL.md frontmatter + skill-runtime contract

**File(s)**: `skills/setup/SKILL.md`
**Type**: Create
**Depends**: None
**Acceptance**:
- [x] Frontmatter declares `name`, `description`, `argument-hint: <vault-path>`, `allowed-tools: Bash, Read, Write, Edit, AskUserQuestion`, `model: sonnet`, `effort: low`
- [x] Description matches keyword triggers listed in `tech.md` (setup, configure, link vault, install)
- [x] Skill loads under the `obsidian-memory:` namespace

---

## Phase 4: Integration

### T002: Config + filesystem orchestration

**File(s)**: `skills/setup/SKILL.md` (behaviour sections 1–4)
**Type**: Create
**Depends**: T001
**Acceptance**:
- [x] Step 1 resolves `$1` or prompts via `AskUserQuestion`; expands leading `~`; aborts on missing directory (AC3)
- [x] Step 2 writes `~/.claude/obsidian-memory/config.json` with `vaultPath`, `rag.enabled=true`, `distill.enabled=true`; preserves extra user keys on re-run (FR2, AC2)
- [x] Step 3 creates `<vault>/claude-memory/sessions/` and manages `projects` symlink per the 4-state table (AC4, AC5)
- [x] Step 4 initializes `<vault>/claude-memory/Index.md` only if absent (FR5, AC2)

### T003: MCP registration + dependency probe + smoke test + final report

**File(s)**: `skills/setup/SKILL.md` (behaviour sections 5–7)
**Type**: Create
**Depends**: T002
**Acceptance**:
- [x] Step 5 prompts via `AskUserQuestion` with Yes/No/Skip; runs `claude mcp add -s user obsidian --transport websocket ws://localhost:22360` on Yes; treats non-zero exit as non-fatal (AC6, AC7)
- [x] Step 6 probes `jq`, `rg`, `claude` with `command -v`; smoke-tests `vault-rag.sh` with a synthetic payload (FR7, FR8, AC8)
- [x] Step 7 prints final report with config path, vault path, symlink target+status, Index path, MCP status, missing deps (FR9)

---

## Phase 5: BDD Testing (Required)

> Tasks in this phase are **deferred** until issue #1 (bats-core + cucumber-shell harness) lands. Acceptance criteria are defined here so /verify-code can execute them as soon as the harness exists.

### T004: Create BDD feature file

**File(s)**: `specs/feature-vault-setup/feature.gherkin`
**Type**: Create
**Depends**: None (authored alongside this spec)
**Acceptance**:
- [x] All 8 acceptance criteria (AC1–AC8) are scenarios
- [x] Scenarios use Given/When/Then format
- [x] File is valid Gherkin syntax

### T005: Implement step definitions

**File(s)**: `tests/features/steps/setup.sh`
**Type**: Create
**Depends**: T004, issue #1
**Acceptance**:
- [ ] One step definition per Given/When/Then clause used in the 8 scenarios
- [ ] All filesystem state lives under `$BATS_TEST_TMPDIR` (scratch `$HOME`, scratch vault)
- [ ] Never touches the operator's real `~/.claude` or real vault
- [ ] Stubs `claude` binary to avoid real MCP calls in CI
- [ ] Passes under `tests/run-bdd.sh`

### T006: Integration tests (bats)

**File(s)**: `tests/integration/setup.bats`
**Type**: Create
**Depends**: issue #1
**Acceptance**:
- [ ] Test: first-run setup produces all four artefacts (AC1)
- [ ] Test: re-running 5× produces zero drift (AC2 + success metric)
- [ ] Test: missing vault path aborts cleanly (AC3)
- [ ] Test: non-symlink `projects` entry is refused without deletion (AC4)
- [ ] Test: stale symlink is repointed atomically (AC5)
- [ ] Test: missing `jq`/`claude` does not fail setup (AC8)
- [ ] Passes under `bats tests/integration`

---

## Dependency Graph

```
T001 ──▶ T002 ──▶ T003

T004 (independent — spec authoring)

T005 ─── depends on T004 and issue #1
T006 ─── depends on issue #1
```

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #9 | 2026-04-19 | Initial baseline task breakdown — documents v0.1.0 shipped implementation; testing phase deferred to #1 |

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
