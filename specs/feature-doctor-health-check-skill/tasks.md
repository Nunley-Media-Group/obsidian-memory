# Tasks: Doctor Health-Check Skill

**Issues**: #2
**Date**: 2026-04-21
**Status**: Planning
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [ ] |
| Backend | 2 | [ ] |
| Integration | 1 | [ ] |
| Testing | 3 | [ ] |
| **Total** | 7 | |

"Backend" means the shell implementation; "Integration" means the user-facing skill wrapper.

---

## Task Format

```
### T[NNN]: [Task Title]

**File(s)**: `path/to/file`
**Type**: Create | Modify
**Depends**: T[NNN] (or None)
**Acceptance**:
- [ ] [Verifiable criterion]
```

---

## Phase 1: Setup

### T001: Create feature directory structure

**File(s)**: `skills/doctor/`, `scripts/`, `tests/integration/`, `tests/features/steps/`
**Type**: Create (directories only; actual files created in later tasks)
**Depends**: None
**Acceptance**:
- [ ] `skills/doctor/` exists (empty, ready for SKILL.md in T005)
- [ ] `scripts/` and `tests/integration/` and `tests/features/steps/` already exist from prior work — verify presence, create if missing

**Notes**: Low-risk directory prep task. Combines creation with presence verification so the task is safely idempotent.

---

## Phase 2: Backend Implementation

### T002: Implement `vault-doctor.sh` probes and human-readable output

**File(s)**: `scripts/vault-doctor.sh`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Shebang `#!/usr/bin/env bash`; `set -u`; `trap` at top level per `steering/tech.md` Bash standards
- [ ] Accepts `--json` flag; anything else prints a short usage line and exits 2
- [ ] Runs every probe P1–P9 and I1–I2 from `design.md` → Data Flow, in order, without short-circuiting
- [ ] Probe P1 (config) reads `$HOME/.claude/obsidian-memory/config.json`
- [ ] Probes P2/P8/P9 use `jq` on `.vaultPath`, `.rag.enabled`, `.distill.enabled`; treat unset `.rag.enabled`/`.distill.enabled` as enabled (matches `_common.sh` behavior)
- [ ] Probe P7 uses plain `readlink` (no `-f`) and compares the target to `$HOME/.claude/projects`; works under BSD readlink on macOS
- [ ] Probe I1 reports `INFO` when `rg` is missing, never `FAIL`
- [ ] Probe I2 runs `claude mcp list` under `timeout 3`, treats non-zero/timeouts as `INFO: mcp status unknown`
- [ ] When `jq` itself is missing, jq-dependent probes degrade to `FAIL: cannot check — jq missing` (do not crash)
- [ ] Human output format matches the sample in `design.md` → Human-mode output format
- [ ] ANSI color codes emitted only when `[ -t 1 ]`
- [ ] Exits 0 when every probe status ∈ {`ok`, `info`}; exits 1 on any `fail`
- [ ] File is read-only at runtime — no `>`, `>>`, `mv`, `rm`, `ln`, or `mkdir` anywhere in the script
- [ ] Passes `shellcheck scripts/vault-doctor.sh`

**Notes**: Do NOT reuse `scripts/_common.sh::om_load_config` — it exits 0 on any failure, which masks the diagnoses doctor must surface. Doctor reads the config directly. Rationale is captured under Alternatives Considered → Option E in `design.md`.

### T003: Add `--json` output mode to `vault-doctor.sh`

**File(s)**: `scripts/vault-doctor.sh` (same script, extends T002)
**Type**: Modify
**Depends**: T002
**Acceptance**:
- [ ] When invoked with `--json`, stdout is a single valid JSON object (pipes through `jq empty` without error)
- [ ] Object shape matches the schema in `design.md` → `--json` output schema
- [ ] Per-check `status` ∈ {`ok`, `fail`, `info`}
- [ ] `FAIL` checks include both `reason` and `hint` fields
- [ ] `INFO` checks include a `note` field
- [ ] Top-level `ok` boolean is `true` iff every status ∈ {`ok`, `info`}
- [ ] Color codes are suppressed in JSON mode (stdout must be pure JSON)
- [ ] Exit code policy matches human mode

**Notes**: Keep JSON assembly in a single `jq -n` call at the end — easier to verify and hardens against bash string-quoting bugs.

---

## Phase 3: Integration

### T004: Write `skills/doctor/SKILL.md`

**File(s)**: `skills/doctor/SKILL.md`
**Type**: Create
**Depends**: T002, T003
**Acceptance**:
- [ ] Frontmatter follows the template in `steering/structure.md` → File Templates → Skill template
- [ ] `name: doctor`, `description:` includes trigger phrases ("check obsidian-memory install", "is my obsidian-memory setup working", "diagnose obsidian-memory", "health check obsidian-memory", "/obsidian-memory:doctor")
- [ ] `allowed-tools: Bash, Read` (no Write / Edit — enforces read-only UX)
- [ ] `model: sonnet`, `effort: low` (matches `setup` and `distill-session`)
- [ ] Body documents the `--json` flag, the read-only guarantee, and lists each check with its remediation hint
- [ ] "When to Use" and "When NOT to Use" sections present
- [ ] Instructs Claude to invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-doctor.sh"` (with `"$@"`), relay the script's exit code and output verbatim, and never call the script twice in one invocation
- [ ] Mentions that `/obsidian-memory:setup`'s success message should point users here (documentation cross-link)

**Notes**: The SKILL.md is intentionally thin. Claude shells out to the script and reports back — it does not re-interpret the results. This preserves the bats-testable contract for the underlying probes.

---

## Phase 5: BDD Testing (Required)

**Every acceptance criterion MUST have a Gherkin scenario.**

### T005: Write BDD feature file

**File(s)**: `specs/feature-doctor-health-check-skill/feature.gherkin`
**Type**: Create
**Depends**: None (can be drafted in parallel with T002)
**Acceptance**:
- [ ] One scenario per AC from `requirements.md`:
  - AC1 → `Scenario: Healthy install passes all checks`
  - AC2 → `Scenario Outline: Specific failure modes report a remediation hint` (9 rows)
  - AC3 → `Scenario: Doctor is read-only`
  - AC4 → `Scenario: ripgrep missing is informational`
  - AC6 → `Scenario: --json emits a machine-readable report`
- [ ] AC5 (scratch `$HOME`) is covered by the `Background:` that declares the scratch harness, not a standalone scenario — rationale noted as a comment in the feature file
- [ ] Valid Gherkin syntax — `tests/run-bdd.sh` parses the file without error
- [ ] Uses declarative phrasing ("I run /obsidian-memory:doctor"), not implementation details

### T006: Implement step definitions

**File(s)**: `tests/features/steps/doctor.sh`
**Type**: Create
**Depends**: T002, T003, T005
**Acceptance**:
- [ ] One step definition per unique Given/When/Then phrase in `feature.gherkin`
- [ ] Step definitions follow the naming convention in `steering/tech.md` → Step Definitions (function name mirrors the step phrasing, `lower_snake_case`)
- [ ] All filesystem state lives under `$BATS_TEST_TMPDIR` per the scratch harness contract
- [ ] Invokes the script under test via `"$PLUGIN_ROOT/scripts/vault-doctor.sh"`
- [ ] `tests/run-bdd.sh` passes with every scenario green
- [ ] Passes `shellcheck tests/features/steps/doctor.sh`

### T007: Add bats integration test

**File(s)**: `tests/integration/doctor.bats`
**Type**: Create
**Depends**: T002, T003
**Acceptance**:
- [ ] `setup()` loads `../helpers/scratch`; `teardown()` calls `assert_home_untouched`
- [ ] One `@test` for the happy path (all probes OK/INFO, exit 0)
- [ ] One `@test` per failure mode F1–F9 (9 tests) asserting the right `FAIL:` line and non-zero exit
- [ ] One `@test` that runs `vault-doctor.sh --json` and pipes the output through `jq empty` plus an `ok: false` assertion in a broken state and `ok: true` in a healthy state
- [ ] One `@test` for the optional-deps path (ripgrep on a hidden `PATH`) — output contains `INFO: ripgrep`, exit 0
- [ ] One `@test` for the read-only invariant — pre-/post-snapshot of the scratch `$VAULT` directory tree matches exactly, in addition to the standard `assert_home_untouched` teardown check
- [ ] `bats tests/integration/doctor.bats` passes

**Notes**: Hide `ripgrep` from a test by prepending a scratch-dir-only `PATH`. Avoid using `sudo` or modifying the real `PATH` beyond the test process. The `claude mcp list` informational probe should be mocked via the existing `tests/helpers/fake-claude.bash` helper or by stubbing `claude` in the scratch `PATH` — whichever is simpler given the harness's current stub conventions.

---

## Dependency Graph

```
T001 ──┬──▶ T002 ──┬──▶ T003 ──┬──▶ T004
       │                       │
       │                       └──▶ T007
       │
       └──▶ T005 ──▶ T006
```

Critical path: T001 → T002 → T003 → T004 (user-invocable feature reaches the skill surface).
Independent track: T005 can begin once requirements.md is approved; T006 joins once T005 and T003 both land.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #2 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to IMPLEMENT phase:

- [x] Each task has single responsibility
- [x] Dependencies are correctly mapped
- [x] Tasks can be completed independently (given dependencies)
- [x] Acceptance criteria are verifiable
- [x] File paths reference actual project structure (per `steering/structure.md`)
- [x] Test tasks are included for each implementation task
- [x] No circular dependencies
- [x] Tasks are in logical execution order
