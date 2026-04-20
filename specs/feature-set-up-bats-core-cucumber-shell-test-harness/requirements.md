# Requirements: bats-core + cucumber-shell test harness

**Issues**: #1
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## User Story

**As a** plugin maintainer
**I want** a working test harness (bats-core unit/integration + cucumber-shell BDD) wired to the Verification Gates declared in `steering/tech.md`
**So that** every future change to hook scripts and skills is verified against acceptance criteria and shellcheck, not by hand against my own vault

---

## Background

`steering/tech.md` declares bats-core for unit and integration tests and cucumber-shell for BDD execution of `specs/*/feature.gherkin` files, plus five Verification Gates (shellcheck, unit, integration, BDD, JSON validity) that `/verify-code` enforces. None of those gates can actually pass today because the harness does not exist: there is no `tests/` tree, no bats wiring, no cucumber-shell runner, and no scratch-vault helper. Every existing baseline spec (#9 vault-setup, #10 RAG, #11 distillation hook, #12 distill skill) currently verifies by hand.

This issue makes the declared gates real. Without it, every subsequent spec is effectively unverified, and `/write-code` on any later feature will fail its verification step. It also blocks the v2 candidates #5 (embedding swap) and #7 (configurable distillation template), which both require a running BDD harness to verify semantic parity with the current scripts.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: bats unit harness runs green on a placeholder test (Happy Path)

**Given** a fresh clone of the repo on macOS or Linux with `bats-core` and `shellcheck` installed
**When** a developer runs `bats tests/unit`
**Then** the command exits 0
**And** reports at least one passing placeholder test (e.g., `tests/unit/smoke.bats` asserting `true`)

### AC2: bats integration harness runs against a scratch vault, never the operator's real vault (Safety)

**Given** the harness is installed
**When** a developer runs `bats tests/integration`
**Then** every test runs under `$BATS_TEST_TMPDIR` with a scratch `$HOME` and scratch vault directory via a shared helper
**And** no file is written anywhere under the operator's real `$HOME/.claude/` or real Obsidian vault during the run
**And** an assertion helper snapshots the operator's real `$HOME` before the test and asserts it is byte-identical after the test

### AC3: cucumber-shell BDD runner executes a feature file and fails on a missing step (Happy Path + Negative)

**Given** a `specs/example/feature.gherkin` file containing one `Given/When/Then` scenario
**And** a matching step definition under `tests/features/steps/example.sh`
**When** a developer runs `tests/run-bdd.sh`
**Then** the runner exits 0 and reports the scenario as passed
**And** removing the step definition causes the next run to exit non-zero with a clear "undefined step" error

### AC4: shellcheck gate passes on every committed `*.sh` file (Happy Path)

**Given** `shellcheck` is installed
**When** a developer runs the shellcheck gate command declared in `steering/tech.md` (`shellcheck scripts/*.sh tests/**/*.sh` with the find-based fallback)
**Then** the command exits 0 against the current repo contents
**And** any pre-existing finding in `scripts/vault-rag.sh` or `scripts/vault-distill.sh` is fixed as part of this issue rather than suppressed

### AC5: JSON-validity gate passes on every manifest (Happy Path)

**Given** `jq` is installed
**When** a developer runs `jq empty .claude-plugin/plugin.json hooks/hooks.json`
**Then** the command exits 0

### AC6: README documents how to install and run the harness (Documentation)

**Given** a new contributor reads `README.md`
**When** they look for a "Development" or "Testing" section
**Then** they find explicit install instructions for `bats-core`, cucumber-shell, and `shellcheck` (with macOS `brew` and Linux `apt`/manual commands)
**And** the three run commands (`bats tests/unit`, `bats tests/integration`, `tests/run-bdd.sh`) with expected pass output

### AC7: `/verify-code` gate discovery picks up the harness (Integration)

**Given** the harness is installed and a real spec (e.g., `specs/feature-vault-setup/`) has at least one Gherkin scenario
**When** a developer or `/verify-code` runner reads `steering/tech.md` and executes every command in the Verification Gates table
**Then** Shellcheck, Unit, Integration, BDD, and JSON validity gates all exit 0
**And** the table wording in `steering/tech.md` matches the commands the harness actually implements (no drift between declared and real)

### AC8: Baseline shipped features pass their Gherkin scenarios (Integration)

**Given** the harness is installed
**And** the four baseline feature specs (`feature-vault-setup` #9, `feature-rag-prompt-injection` #10, `feature-session-distillation-hook` #11, `feature-manual-distill-skill` #12) all have their existing `feature.gherkin` files intact
**When** a developer runs `tests/run-bdd.sh`
**Then** every scenario across all four feature files passes
**And** the runner exits 0
**And** every hook / skill invocation inside those scenarios executes against the scratch vault, never the operator's real vault

### Generated Gherkin Preview

```gherkin
Feature: bats-core + cucumber-shell test harness
  As a plugin maintainer
  I want a working test harness wired to the declared Verification Gates
  So that every future change is verified, not eyeballed

  Scenario: bats unit harness runs green
    Given a fresh clone with bats-core installed
    When the developer runs "bats tests/unit"
    Then the command exits 0
    And at least one placeholder test passes

  Scenario: integration tests never touch the operator's real vault
    Given the integration harness is installed
    When the developer runs "bats tests/integration"
    Then every test runs under $BATS_TEST_TMPDIR with a scratch $HOME
    And the operator's real $HOME/.claude is byte-identical after the run

  Scenario: BDD runner fails loudly on a missing step
    Given a feature file with one scenario and a matching step definition
    When the developer runs "tests/run-bdd.sh"
    Then the scenario passes and the runner exits 0
    And removing the step definition causes the next run to exit non-zero

  # ... remaining ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Create `tests/unit/`, `tests/integration/`, `tests/features/steps/`, and `tests/run-bdd.sh` at the repo root per `steering/structure.md` | Must | Matches the layout already declared in `structure.md` |
| FR2 | Add `tests/helpers/scratch.bash` exporting `HOME=$BATS_TEST_TMPDIR/home`, creating a scratch vault at `$BATS_TEST_TMPDIR/vault`, and exposing `$PLUGIN_ROOT` pointing at the repo root | Must | Hot path for AC2's "never touch real vault" guarantee |
| FR3 | Add a smoke `*.bats` test under each of `tests/unit/` and `tests/integration/` so both `bats` commands have a non-empty target set | Must | Satisfies the "directory exists" gate condition in `tech.md` |
| FR4 | Write `tests/run-bdd.sh` to invoke cucumber-shell against every `specs/*/feature.gherkin` with step definitions resolved from `tests/features/steps/`. Exit 0 only if every scenario passes; exit non-zero on any undefined step or failed assertion | Must | Matches the BDD gate row in `tech.md` |
| FR5 | Add an assertion helper (e.g., `assert_home_untouched`) used by every integration test; it snapshots the real `$HOME/.claude` state before the test and asserts identity after | Must | AC2's "snapshot and compare" guarantee |
| FR6 | Fix any existing shellcheck findings in `scripts/vault-rag.sh` and `scripts/vault-distill.sh` so the shellcheck gate exits 0 on the current repo | Must | AC4; no `# shellcheck disable=` unless justified inline |
| FR7 | Add a placeholder `specs/example/feature.gherkin` + step definition so AC3 has a subject to execute; clearly marked as a safe-to-delete example | Should | Provides a deterministic AC3 subject that does not depend on real spec churn |
| FR8 | Document installation of `bats-core`, cucumber-shell, and `shellcheck` in `README.md` Development section with macOS `brew` and Linux `apt`/manual commands, plus the three run commands with expected output | Must | AC6 |
| FR9 | Keep the command strings in `steering/tech.md` Verification Gates table byte-identical to the commands the harness actually supports; any rename lands in both places in the same commit | Must | AC7; `/verify-code` reads `tech.md` as the contract |
| FR10 | CI (GitHub Actions) wiring that runs all four gates on every PR | Could | Tracked as a follow-up issue; out of scope for this one |
| FR11 | Step-definition library `tests/features/steps/setup.sh` covering every Given/When/Then in `specs/feature-vault-setup/feature.gherkin` (#9) | Must | Exercises `/obsidian-memory:setup` end-to-end against the scratch vault |
| FR12 | Step-definition library `tests/features/steps/rag.sh` covering every step in `specs/feature-rag-prompt-injection/feature.gherkin` (#10) | Must | Exercises `scripts/vault-rag.sh` via piped hook payload |
| FR13 | Step-definition library `tests/features/steps/distill.sh` covering every step in `specs/feature-session-distillation-hook/feature.gherkin` (#11) | Must | Exercises `scripts/vault-distill.sh`; stubs nested `claude -p` via a fake-binary on PATH so scenarios are deterministic |
| FR14 | Step-definition library `tests/features/steps/manual-distill.sh` covering every step in `specs/feature-manual-distill-skill/feature.gherkin` (#12) | Must | Exercises `/obsidian-memory:distill-session`; same `claude -p` fake-binary approach as FR13 |
| FR15 | `tests/run-bdd.sh` exits 0 on a clean run against all four baseline specs plus `specs/example/` | Must | AC8; the deterministic green-on-main state the CI follow-up will enforce |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Full `bats tests/unit` + `bats tests/integration` wall time < 10 s on a dev laptop; `tests/run-bdd.sh` against the placeholder feature < 5 s. These are targets, not gates. |
| **Security** | Tests must never read or write under the operator's real `$HOME/.claude/` or real vault. `assert_home_untouched` is the backstop. |
| **Reliability** | All gates deterministic — no tests that depend on network, current time, or `rg` being on a specific PATH (POSIX fallback must be exercised at least once). |
| **Platforms** | macOS default bash 3.2, Linux bash 4+, per `steering/tech.md`. No GNU-only flags in test helpers. |
| **Accessibility** | N/A — developer-only harness. |

---

## UI/UX Requirements

Not applicable. The harness is a developer CLI; its "UI" is the pass/fail output of `bats` and `tests/run-bdd.sh`, plus the Development section of `README.md`.

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `$BATS_TEST_TMPDIR` | path (env var) | provided by bats; tests assume it exists | Yes |
| `$PLUGIN_ROOT` | path (env var) | absolute path to the repo root; set by `tests/helpers/scratch.bash` | Yes |
| `specs/*/feature.gherkin` | Gherkin file | valid Gherkin syntax parseable by cucumber-shell | Yes (at least one) |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| `bats` stdout | TAP-compatible test output | One line per test; final summary with pass/fail counts |
| `tests/run-bdd.sh` stdout | cucumber-shell scenario output | Per-scenario pass/fail; final summary; non-zero exit on any failure or undefined step |
| `shellcheck` stdout | diagnostic findings | Empty on pass; non-zero exit and per-finding detail on fail |

---

## Dependencies

### Internal Dependencies

- [ ] `scripts/vault-rag.sh`, `scripts/vault-distill.sh` — subjects of the shellcheck gate (FR6)
- [ ] `steering/tech.md` — Verification Gates table is the contract the harness must match (FR9, AC7)
- [ ] Existing baseline specs (#9, #10, #11, #12) — their `feature.gherkin` files will be picked up by `tests/run-bdd.sh` as they are authored

### External Dependencies

- [ ] `bats-core` — https://github.com/bats-core/bats-core (brew: `bats-core`; apt: `bats`)
- [ ] cucumber-shell — shell-native Gherkin runner named in `steering/tech.md`
- [ ] `shellcheck` ≥ 0.9 — brew: `shellcheck`; apt: `shellcheck`
- [ ] `jq` ≥ 1.6 — already required by hooks at runtime

### Blocked By

- [ ] None — this issue is the unblock for #5 and #7.

---

## Out of Scope

- GitHub Actions / CI wiring — tracked as a follow-up issue; this issue only builds the dev-time harness (FR10 is `Could`).
- Embedding-based retrieval work (tracked separately as #5).
- Modifying the baseline specs' `feature.gherkin` content — this issue only authors the step definitions that make the existing scenarios runnable. If a scenario's wording is ambiguous enough that a step definition cannot be written without changing the Gherkin, the spec's author (the issue that authored it) owns the rewording; this issue documents the ambiguity and exits.
- Pinning a specific cucumber-shell version or vendoring it into the repo — the runner is hand-rolled (see design.md), so there is no external version to pin.
- Writing new spec scenarios beyond what the four baseline specs + `specs/example/` already contain.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Gate drift | 0 — every command in `steering/tech.md` Verification Gates table is the exact command the harness runs | Manual diff of `tech.md` vs `tests/run-bdd.sh` + documented shellcheck invocation on every PR touching either file |
| Real-vault contamination | 0 files created under the operator's real `$HOME/.claude/` or real vault across a full `bats tests/integration` run | `assert_home_untouched` backstop (FR5) runs in every integration test |
| Time from "fresh clone" to "all gates green" | < 15 minutes including dep install on macOS | Informal: any new contributor following README Development section |

---

## Open Questions

- [ ] cucumber-shell is referenced in `steering/tech.md` but is not a widely packaged tool. Resolution belongs in design.md — whether to depend on a specific upstream project, vendor a minimal runner, or ship a thin bash wrapper over bats. This spec only states the **behavioral** requirement (AC3, FR4); the implementation choice is deferred to PLAN.
- [ ] Whether the `specs/example/` placeholder lives under `specs/` (picked up by `tests/run-bdd.sh` naturally) or under `tests/features/example/` (kept out of the production spec set). Deferred to design.md.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #1 | 2026-04-19 | Initial feature spec — bats-core + cucumber-shell test harness wired to declared Verification Gates |
| #1 | 2026-04-19 | Expanded scope: also author step definitions for the four baseline specs (#9, #10, #11, #12) and assert `tests/run-bdd.sh` exits 0 across all of them (AC8, FR11–FR15) |

---

## Validation Checklist

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements (cucumber-shell implementation choice deferred to PLAN)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases and error states are specified (AC3 negative path, AC2 safety backstop)
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented
