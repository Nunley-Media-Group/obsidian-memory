# Tasks: bats-core + cucumber-shell test harness

**Issues**: #1
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| 1. Setup (scaffolding) | 3 | [ ] |
| 2. Backend (runner + helpers) | 3 | [ ] |
| 3. Documentation (README) | 1 | [ ] |
| 4. Integration (step defs + shellcheck fixes) | 7 | [ ] |
| 5. Testing (meta-tests + gate sweep) | 4 | [ ] |
| **Total** | **18** | |

---

## Task Format

Each task follows this structure:

```
### T[NNN]: [Task Title]

**File(s)**: `path/to/file`
**Type**: Create | Modify | Delete
**Depends**: T[NNN], T[NNN] (or None)
**Acceptance**:
- [ ] [Verifiable criterion]
```

File paths follow `steering/structure.md` — tests live at `tests/` (repo root), steps at `tests/features/steps/`, scripts at `scripts/`.

---

## Phase 1: Setup

### T001: Create tests directory scaffolding

**File(s)**: `tests/unit/`, `tests/integration/`, `tests/features/steps/`, `tests/helpers/`
**Type**: Create
**Depends**: None
**Acceptance**:
- [ ] All four directories exist at the repo root
- [ ] Each contains a `.gitkeep` or a real file (no empty committed dirs)
- [ ] Directory layout matches `steering/structure.md` §Project Layout exactly (FR1)

### T002: Create `specs/example/feature.gherkin` placeholder

**File(s)**: `specs/example/feature.gherkin`
**Type**: Create
**Depends**: None
**Acceptance**:
- [ ] One `Feature:` with one `Scenario:` containing one `Given/When/Then` triple
- [ ] File header clearly states "Example — safe to delete once real specs have step definitions" (FR7)
- [ ] The scenario is deterministic — no timestamps, no network, no real vault

### T003: Smoke bats tests under unit and integration

**File(s)**: `tests/unit/smoke.bats`, `tests/integration/smoke.bats`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Each file has at least one `@test` that asserts `true` (or a trivially-true condition)
- [ ] `bats tests/unit` exits 0 (AC1)
- [ ] `bats tests/integration` exits 0 (FR3)

---

## Phase 2: Backend — runner + helpers

### T004: Implement `tests/helpers/scratch.bash`

**File(s)**: `tests/helpers/scratch.bash`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Exports `REAL_HOME="$HOME"` before overriding
- [ ] Sets `HOME="$BATS_TEST_TMPDIR/home"`; creates the directory and `$HOME/.claude/`
- [ ] Sets `VAULT="$BATS_TEST_TMPDIR/vault"`; creates the directory
- [ ] Exports `PLUGIN_ROOT` — resolved from `BATS_TEST_DIRNAME` or the repo root
- [ ] Defines `assert_home_untouched` that snapshots `$REAL_HOME/.claude` state in `setup()` and compares in `teardown()`; fails the test if the digest differs (FR2, FR5, AC2)
- [ ] Shebang-less (sourced only, never executed)
- [ ] Passes `shellcheck tests/helpers/scratch.bash`

### T005: Implement `tests/helpers/fake-claude.bash`

**File(s)**: `tests/helpers/fake-claude.bash`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Exposes `install_fake_claude` that creates `$BATS_TEST_TMPDIR/bin/claude` and prepends the dir to `$PATH`
- [ ] Fake `claude` emits a minimal markdown note (frontmatter + `# Session`, `## Decisions`, `## Patterns`, `## Open Threads`) matching `vault-distill.sh`'s parser expectations
- [ ] Works under `macOS` default bash 3.2 (no `declare -g`, no associative arrays)
- [ ] Passes `shellcheck tests/helpers/fake-claude.bash`

### T006: Implement `tests/run-bdd.sh`

**File(s)**: `tests/run-bdd.sh`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Parses every `specs/*/feature.gherkin` line-by-line (Feature/Background/Scenario/Given/When/Then/And)
- [ ] Normalizes step text to a function name via a pure `tr`/`sed` pipeline (see design.md §Data Flow)
- [ ] Sources `tests/helpers/scratch.bash` + `tests/features/steps/common.sh` + any other referenced `*.sh` in a fresh subshell per scenario
- [ ] Exit code `0` on all-green; `1` on assertion failure; `2` on undefined step; other on internal failure (design.md §Runner exit-code contract)
- [ ] Never `eval`s step text; step text is normalized then dispatched (Security §Input Validation)
- [ ] Emits a final summary: `<N> scenarios, <M> passed, <K> failed, <U> undefined steps`
- [ ] Shebang `#!/usr/bin/env bash`; `set -u`; `chmod +x`
- [ ] Passes `shellcheck tests/run-bdd.sh`

---

## Phase 3: Documentation

### T007: README.md Development section

**File(s)**: `README.md`
**Type**: Modify
**Depends**: T003, T006
**Acceptance**:
- [ ] New "Development" or "Testing" section present
- [ ] Install instructions for `bats-core`, `shellcheck`, and `jq` with macOS `brew` commands and Linux `apt`/manual commands
- [ ] Run commands documented: `bats tests/unit`, `bats tests/integration`, `tests/run-bdd.sh`, shellcheck gate command, JSON-validity gate command
- [ ] Cross-references `steering/tech.md` §Verification Gates as the authoritative source (FR8, AC6)

---

## Phase 4: Integration

### T008: Fix pre-existing shellcheck findings in shipped scripts

**File(s)**: `scripts/vault-rag.sh`, `scripts/vault-distill.sh`, `scripts/_common.sh`
**Type**: Modify
**Depends**: None
**Acceptance**:
- [ ] `shellcheck scripts/*.sh` exits 0 (AC4, FR6)
- [ ] No `# shellcheck disable=` comments unless each is annotated with a one-line justification
- [ ] No behavior change — diff review shows only `local` additions, quoting fixes, `$()` vs backticks, unused-var cleanup
- [ ] Hooks still silent-no-op on missing deps/config (smoke via `HOOK_INPUT='{}' bash scripts/vault-rag.sh` exits 0)

### T009: Shared step definitions — `common.sh`

**File(s)**: `tests/features/steps/common.sh`
**Type**: Create
**Depends**: T004, T005, T006
**Acceptance**:
- [ ] Defines step functions for every phrase used in `Background:` blocks across the four baseline specs (e.g., "a scratch HOME at …", "a scratch Obsidian vault at …", "obsidian-memory is installed and setup against …")
- [ ] Each step function is idempotent and uses only `$BATS_TEST_TMPDIR` paths
- [ ] Installs the fake `claude` binary (from T005) when a Background or Scenario references distillation
- [ ] Passes `shellcheck tests/features/steps/common.sh`

### T010: Example step definitions — `example.sh`

**File(s)**: `tests/features/steps/example.sh`
**Type**: Create
**Depends**: T002, T006, T009
**Acceptance**:
- [ ] Defines every function referenced by `specs/example/feature.gherkin`
- [ ] Runs green via `tests/run-bdd.sh specs/example/feature.gherkin` (or whatever the runner's single-file invocation is)
- [ ] Removing this file causes `tests/run-bdd.sh` to exit 2 with a clear "undefined step" error (AC3)

### T011: Setup step definitions — `setup.sh` (#9)

**File(s)**: `tests/features/steps/setup.sh`
**Type**: Create
**Depends**: T008, T009
**Acceptance**:
- [ ] Defines every function referenced by `specs/feature-vault-setup/feature.gherkin` (all scenarios)
- [ ] Invokes the `/obsidian-memory:setup` shell equivalent against the scratch vault (header comment documents which SKILL.md it reproduces)
- [ ] Every scenario in `specs/feature-vault-setup/feature.gherkin` passes via `tests/run-bdd.sh`
- [ ] `assert_home_untouched` invariant holds across every scenario (no writes to real `$HOME/.claude/`)

### T012: RAG step definitions — `rag.sh` (#10)

**File(s)**: `tests/features/steps/rag.sh`
**Type**: Create
**Depends**: T008, T009
**Acceptance**:
- [ ] Defines every function referenced by `specs/feature-rag-prompt-injection/feature.gherkin`
- [ ] Pipes a JSON hook payload into `scripts/vault-rag.sh` and captures stdout + exit code
- [ ] Asserts `<vault-context>` block presence/absence per scenario
- [ ] Exercises both the `rg` and POSIX `grep -r`/`find` paths at least once (sandboxing PATH to remove `rg` for the fallback scenario)
- [ ] Every scenario in the feature file passes via `tests/run-bdd.sh`

### T013: Distillation hook step definitions — `distill.sh` (#11)

**File(s)**: `tests/features/steps/distill.sh`
**Type**: Create
**Depends**: T005, T008, T009
**Acceptance**:
- [ ] Defines every function referenced by `specs/feature-session-distillation-hook/feature.gherkin`
- [ ] Uses `install_fake_claude` so `scripts/vault-distill.sh` sees a deterministic `claude -p` stdout
- [ ] Seeds `$HOME/.claude/projects/<slug>/*.jsonl` fixtures in the scratch HOME
- [ ] Asserts the distilled note lands under `$VAULT/claude-memory/sessions/<slug>/` and `Index.md` gets a link appended
- [ ] Every scenario in the feature file passes via `tests/run-bdd.sh`

### T014: Manual distill-session step definitions — `manual-distill.sh` (#12)

**File(s)**: `tests/features/steps/manual-distill.sh`
**Type**: Create
**Depends**: T005, T009, T013
**Acceptance**:
- [ ] Defines every function referenced by `specs/feature-manual-distill-skill/feature.gherkin`
- [ ] Reuses `install_fake_claude` from T005 and shared helpers from T013 where sensible
- [ ] Every scenario in the feature file passes via `tests/run-bdd.sh`

---

## Phase 5: BDD Testing (Required)

**Every acceptance criterion MUST have a Gherkin test.**

The harness's own `feature.gherkin` is authored in T015; T016 wires step definitions; T017 validates the AC3 negative path; T018 is the full gate sweep that validates AC7 and AC8.

### T015: Create harness BDD feature file

**File(s)**: `specs/feature-set-up-bats-core-cucumber-shell-test-harness/feature.gherkin`
**Type**: Create (already drafted alongside this file)
**Depends**: None
**Acceptance**:
- [ ] Every AC1–AC8 has a corresponding scenario
- [ ] Valid Gherkin syntax parseable by `tests/run-bdd.sh`
- [ ] Uses concrete scratch paths; no magic globals beyond `$BATS_TEST_TMPDIR`, `$HOME`, `$VAULT`, `$PLUGIN_ROOT`

### T016: Implement harness step definitions

**File(s)**: `tests/features/steps/harness.sh`
**Type**: Create
**Depends**: T004, T005, T006, T015
**Acceptance**:
- [ ] Defines every step referenced by the harness's own `feature.gherkin`
- [ ] AC3 negative-path step runs `tests/run-bdd.sh` against a subject feature with the step definition removed and asserts exit code 2
- [ ] Scenarios pass under `tests/run-bdd.sh specs/feature-set-up-bats-core-cucumber-shell-test-harness/feature.gherkin`

### T017: AC3 negative-path meta-test (bats)

**File(s)**: `tests/integration/run_bdd.bats`
**Type**: Create
**Depends**: T006, T010
**Acceptance**:
- [ ] A `@test` asserts `tests/run-bdd.sh` exits 0 on the example feature with its step file present
- [ ] A second `@test` temporarily moves `tests/features/steps/example.sh` aside and asserts exit code `2` with stderr containing "undefined step"
- [ ] `assert_home_untouched` holds across both tests

### T018: Full gate sweep + tech.md drift check

**File(s)**: `tests/integration/gate_sweep.bats`, `steering/tech.md`
**Type**: Create (+ verify `tech.md` unchanged)
**Depends**: T003, T006, T008, T011, T012, T013, T014
**Acceptance**:
- [ ] Bats test runs each of the five commands from `steering/tech.md` §Verification Gates and asserts exit 0
- [ ] A drift-check asserts the command strings in `tests/run-bdd.sh`, `tests/integration/gate_sweep.bats`, and `steering/tech.md` are byte-identical (FR9, AC7)
- [ ] The full sweep passes on a clean repo (AC8 via the scenarios exercised through `tests/run-bdd.sh`)

---

## Dependency Graph

```
T001 ──┬──▶ T003 ──▶ T007
       │
       ├──▶ T004 ──┬──▶ T009 ──┬──▶ T010 ──▶ T017
       │           │           │
       │           │           ├──▶ T011 ──┐
       │           │           │           │
       │           │           ├──▶ T012 ──┤
       │           │           │           │
       │           │           ├──▶ T013 ──┤
       │           │           │           │
       │           │           └──▶ T014 ──┤
       │           │                       │
       │           └──▶ T006 ──▶ T017      │
       │                                    ▼
       ├──▶ T005 ──▶ T013, T014         T018
       │
       └──▶ T002 ──▶ T010

T008 ──▶ T011, T012, T013, T014, T018

T015 ──▶ T016
```

Critical path: `T001 → T004 → T006 → T009 → T011 → T018`

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #1 | 2026-04-19 | Initial task breakdown — 18 tasks across 5 phases including step-def authoring for baseline specs #9–#12 |

---

## Validation Checklist

- [x] Each task has single responsibility
- [x] Dependencies are correctly mapped (see Dependency Graph)
- [x] Tasks can be completed independently given dependencies
- [x] Acceptance criteria are verifiable (every [ ] is a pass/fail command or file check)
- [x] File paths reference actual project structure per `structure.md`
- [x] BDD test tasks are included (T015, T016, T017, T018)
- [x] No circular dependencies
- [x] Tasks are in logical execution order
