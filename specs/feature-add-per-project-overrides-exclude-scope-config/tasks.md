# Tasks: Per-Project Overrides (Exclude / Scope Config)

**Issues**: #6
**Date**: 2026-04-22
**Status**: Planning
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 2 | [ ] |
| Backend (scripts) | 4 | [ ] |
| Frontend (skill) | 1 | [ ] |
| Integration (hooks / doctor) | 3 | [ ] |
| Testing | 4 | [ ] |
| **Total** | **14** | |

---

## Phase 1: Setup

### T001: Length-cap `om_slug` in `scripts/_common.sh`

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: None
**Acceptance**:
- [ ] `om_slug` pipes the existing output through `cut -c1-60` and re-strips a trailing hyphen exposed by the truncation.
- [ ] No existing caller (`vault-distill.sh`) breaks — its `SLUG="$(om_slug "$CWD")"` call site still produces a valid filesystem name.
- [ ] A cwd whose basename is ≤ 60 chars yields byte-identical output to the pre-change helper.
- [ ] A cwd whose basename is > 60 chars yields a ≤ 60-char slug with no leading/trailing hyphens.

**Notes**: See `design.md` → Modified `om_slug` helper for the exact pipeline. Trailing-hyphen re-strip after `cut` handles the edge case where truncation lands on a `-`.

### T002: Extend setup's `config.json` scaffold with empty `projects` stanza

**File(s)**: `skills/setup/SKILL.md`, `scripts/vault-setup.sh` (whichever owns the config creation — confirm in the codebase; if only SKILL.md, update it there)
**Type**: Modify
**Depends**: None
**Acceptance**:
- [ ] A fresh `/obsidian-memory:setup <vault>` produces a config that includes `"projects": {"mode": "all", "excluded": [], "allowed": []}`.
- [ ] Re-running setup against an existing config does NOT overwrite a pre-existing `projects` stanza (idempotency invariant from `steering/product.md` → Success Metrics).
- [ ] 2-space indentation preserved (`jq --indent 2`).

**Notes**: If setup logic lives only in `skills/setup/SKILL.md` as an LLM-authored script, update the instructions there. If a `vault-setup.sh` exists, prefer changing the script for testability.

---

## Phase 2: Backend Implementation (hot-path helpers + scope script)

### T003: Add `om_project_allowed` and `om_policy_state` helpers to `_common.sh`

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: T001
**Acceptance**:
- [ ] `om_project_allowed "$CWD"` returns 0 when policy permits, 1 when it does not.
- [ ] Missing `projects` stanza → treated as `mode = "all"` with empty lists (permissive).
- [ ] Unknown `projects.mode` value → coerced to `"all"` with a single-line stderr warning.
- [ ] Non-array `projects.excluded` / `projects.allowed` → treated as empty; stderr warning.
- [ ] `om_policy_state "$CWD"` echoes exactly one of `all`, `excluded`, `allowlist-hit`, `allowlist-miss`.
- [ ] Private `_om_slug_in_csv` helper correctly splits jq's `@csv` output (handles quoted commas and empty lists).
- [ ] Unit test `tests/unit/common.bats` covers every branch.

**Notes**: See `design.md` → New `om_project_allowed` helper for the jq filter. Quote handling on `@csv` output is the subtle bit — prefer a shell loop over `echo | cut`.

### T004: Create `scripts/vault-scope.sh` with all verbs and atomic writes

**File(s)**: `scripts/vault-scope.sh` (new)
**Type**: Create
**Depends**: T003
**Acceptance**:
- [ ] Implements every verb from requirements.md AC5: `status`, `current`, `mode`, `exclude {add,remove,list}`, `allow {add,remove,list}`.
- [ ] Atomic write: temp file in `$CONFIG`'s directory, `jq --indent 2` render, `mv` commit; `EXIT` trap removes stray temp files.
- [ ] Exit codes: 0 success, 1 runtime error, 2 bad usage (mirrors `vault-toggle.sh`).
- [ ] `ERROR:`-prefixed stderr messages on every error path.
- [ ] `exclude add` / `allow add` with no `<slug>` argument default to `om_slug "$PWD"`.
- [ ] `exclude add` / `allow add` re-normalize the slug through `om_slug` before writing (FR13).
- [ ] Mutations preserve every unrelated config key byte-for-byte.
- [ ] No-op paths (`exclude add` of an already-present slug) print `projects.excluded already contains "<slug>"` and exit 0 WITHOUT rewriting the file (mtime + inode preserved).
- [ ] `mode allowlist` with empty `projects.allowed` emits `WARNING: allowlist mode with no allowed projects — all projects will no-op` to stderr; still exits 0.
- [ ] Shebang `#!/usr/bin/env bash`, `set -u`, `ERR` trap per `steering/tech.md` → Coding Standards.
- [ ] File is executable (chmod +x).

**Notes**: Copy the `TMP` / `mv` / `EXIT` trap pattern verbatim from `scripts/vault-toggle.sh`. The mutation filter for `exclude add` is `.projects.excluded = ((.projects.excluded // []) + [$slug] | unique)`; symmetric for `remove` with `map(select(. != $slug))`. Mid-session-caveat line is appended to stdout when the mutation changes which bucket the current project falls into (requires reading the pre- and post-mutation `om_policy_state` against `$PWD`).

### T005: Create `scripts/vault-session-start.sh`

**File(s)**: `scripts/vault-session-start.sh` (new)
**Type**: Create
**Depends**: T003
**Acceptance**:
- [ ] Reads SessionStart payload from stdin; extracts `session_id` and `cwd`.
- [ ] Falls back to `$PWD` when `cwd` is missing from payload.
- [ ] Exits 0 silently when `session_id` is missing or config is absent.
- [ ] Creates `~/.claude/obsidian-memory/session-policy/` on demand.
- [ ] Writes a single-line file `<session_id>.state` containing one of `all`, `excluded`, `allowlist-hit`, `allowlist-miss`.
- [ ] Never exits non-zero; `ERR` trap + explicit `|| exit 0` on every I/O path.
- [ ] Shellcheck clean.
- [ ] File is executable.

**Notes**: See `design.md` → New `scripts/vault-session-start.sh` for the full body. Does NOT call `om_load_config` — snapshots must be taken even when `rag`/`distill` are toggled off individually, so a later toggle-on finds a usable snapshot.

### T006: Gate `scripts/vault-rag.sh` and `scripts/vault-distill.sh` on the policy

**File(s)**: `scripts/vault-rag.sh`, `scripts/vault-distill.sh`
**Type**: Modify
**Depends**: T003
**Acceptance**:
- [ ] `vault-rag.sh` reads `cwd` from the UserPromptSubmit payload (fallback `$PWD`) before dispatching to a backend; calls `om_project_allowed "$CWD" || exit 0` after `om_load_config rag`.
- [ ] The payload is still tee'd to the scratch temp file for backend replay (existing dispatcher behavior preserved).
- [ ] Neither `vault-rag-keyword.sh` nor `vault-rag-embedding.sh` is modified — the gate lives in the dispatcher (FR8; preserves one-script-swap invariant).
- [ ] `vault-distill.sh` reads the per-session snapshot at `~/.claude/obsidian-memory/session-policy/<session_id>.state` first; removes the file after reading.
- [ ] On snapshot `excluded` / `allowlist-miss`, `vault-distill.sh` exits 0 without writing any vault file.
- [ ] On snapshot `all` / `allowlist-hit`, `vault-distill.sh` proceeds with existing distillation.
- [ ] On missing/unreadable snapshot, `vault-distill.sh` falls back to `om_project_allowed "$CWD" || exit 0`.
- [ ] Existing guards (`om_load_config distill`, transcript-size threshold, empty convo) still run — the scope check is additive, not a replacement.

**Notes**: See `design.md` → Modified `scripts/vault-rag.sh` and Modified `scripts/vault-distill.sh` for the exact insertion points.

---

## Phase 3: Frontend (skill surface)

### T007: Create `skills/scope/SKILL.md` (thin-relayer)

**File(s)**: `skills/scope/SKILL.md` (new)
**Type**: Create
**Depends**: T004
**Acceptance**:
- [ ] Follows the shape of `skills/toggle/SKILL.md` and `skills/doctor/SKILL.md` (frontmatter: `name`, `description`, `argument-hint`, `allowed-tools`, `model`, `effort`).
- [ ] `name: scope`; description lists the verbs and trigger phrases (e.g., "exclude this project", "scope to allowlist", "show scope status").
- [ ] "When to Use" / "When NOT to Use" sections per structure.md skill template.
- [ ] Invocation block documents every verb from AC5.
- [ ] "Behavior" section: shells out once to `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-scope.sh" "$@"` and relays stdout + exit code verbatim.
- [ ] "Exit Code Contract" table (0 / 1 / 2) matches `vault-scope.sh`.
- [ ] "Error handling" section enumerates: missing config, missing jq, unknown verb/mode, failed write.
- [ ] "Idempotency" section explains: status / list verbs are pure reads; mutations only rewrite the file when the content changes.
- [ ] "Related skills" section cross-references `/obsidian-memory:setup`, `/obsidian-memory:toggle`, `/obsidian-memory:doctor`.

**Notes**: Copy the structural scaffold from `skills/toggle/SKILL.md` — thin-relayer pattern, no embedded logic.

---

## Phase 4: Integration

### T008: Wire `SessionStart` in `hooks/hooks.json`

**File(s)**: `hooks/hooks.json`
**Type**: Modify
**Depends**: T005
**Acceptance**:
- [ ] `SessionStart` entry added pointing to `${CLAUDE_PLUGIN_ROOT}/scripts/vault-session-start.sh`.
- [ ] Existing `UserPromptSubmit` and `SessionEnd` entries unchanged.
- [ ] `jq empty hooks/hooks.json` exits 0 (JSON validity gate from `steering/tech.md` → Verification Gates).

**Notes**: Keep the same envelope shape Claude Code's plugin schema uses for the other two hooks.

### T009: Add `scope_mode` probe to `scripts/vault-doctor.sh`

**File(s)**: `scripts/vault-doctor.sh`
**Type**: Modify
**Depends**: T003
**Acceptance**:
- [ ] `probe_scope_mode()` function added per `design.md`.
- [ ] Called from `main()` between `probe_flag_enabled distill` and `probe_ripgrep`.
- [ ] Records as `INFO` in both human and `--json` output.
- [ ] Human detail: `all (unscoped)` when default; `<mode> (excluded: N, allowed: M)` otherwise.
- [ ] JSON detail: `scope_mode.note` contains the same string.
- [ ] Doctor remains read-only (no writes anywhere in the new code).
- [ ] `probe_scope_mode` handles missing `jq` / unreadable config by recording `info` with `cannot read — config or jq missing`.

**Notes**: The probe goes alongside `ripgrep` and `mcp` as an INFO row — not a pass/fail gate. Default mode should never render as FAIL.

### T010: Update `skills/doctor/SKILL.md` "Checks Performed" table

**File(s)**: `skills/doctor/SKILL.md`
**Type**: Modify
**Depends**: T009
**Acceptance**:
- [ ] New row added to the "Checks Performed" table: `scope_mode` with status vocabulary `info` and no remediation hint (it is informational, not a failure).
- [ ] No other changes to the doctor skill (remediation hints, invocation, behavior sections stay intact).

**Notes**: Small doc sync; keeps the skill's inventory accurate.

---

## Phase 5: BDD + Unit + Integration Testing (Required)

**Every acceptance criterion MUST have a Gherkin scenario.** Reference `steering/tech.md` → Testing Standards for framework and layout.

### T011: Create BDD feature file

**File(s)**: `specs/feature-add-per-project-overrides-exclude-scope-config/feature.gherkin`
**Type**: Create
**Depends**: T004, T006, T008, T009
**Acceptance**:
- [ ] File is valid Gherkin (runs through `tests/run-bdd.sh` without parse errors).
- [ ] One scenario per AC (AC1–AC8); AC5's verb table becomes a Scenario Outline.
- [ ] Background uses `$VAULT` and a scratch config at `$HOME/.claude/obsidian-memory/config.json` (scratch `$HOME` per `steering/tech.md` — never the operator's real home).
- [ ] Scenario names match AC names for traceability.

**Notes**: Authored in parallel with this spec (see `feature.gherkin`); T011 ensures it matches the final verb set once T004 lands.

### T012: Implement BDD step definitions for scope scenarios

**File(s)**: `tests/features/steps/vault-scope.sh` (new)
**Type**: Create
**Depends**: T011
**Acceptance**:
- [ ] Every Given/When/Then from `feature.gherkin` has a matching step function.
- [ ] Step functions follow the naming convention in `steering/tech.md` (mirror the Given/When/Then phrasing).
- [ ] All filesystem state lives under `$BATS_TEST_TMPDIR`; tests never touch the operator's real `~/.claude` or Obsidian vault.
- [ ] `tests/run-bdd.sh` executes the new scenarios with exit code 0.

**Notes**: Reuse any common step harness (config-seeding, hook-invocation helper) from existing `tests/features/steps/*.sh` — prefer extending a shared helper over duplicating seed logic.

### T013: Unit tests for `_common.sh` helpers and `vault-scope.sh`

**File(s)**: `tests/unit/common.bats` (modify), `tests/unit/vault-scope.bats` (new)
**Type**: Create / Modify
**Depends**: T001, T003, T004
**Acceptance**:
- [ ] `common.bats`: assertions for `om_slug` length cap (60), trailing-hyphen strip after truncate, basename stability.
- [ ] `common.bats`: assertions for `om_project_allowed` across every branch (mode=all + excluded hit, mode=all + not in excluded, mode=allowlist + in allowed, mode=allowlist + not in allowed, missing stanza, malformed mode, malformed arrays).
- [ ] `common.bats`: assertions for `om_policy_state` returning the four expected values.
- [ ] `vault-scope.bats`: one test per verb — `status`, `current`, `mode all`, `mode allowlist`, `exclude add` (new), `exclude add` (duplicate), `exclude remove` (present), `exclude remove` (absent), `exclude list`, `allow add` / `allow remove` / `allow list`.
- [ ] `vault-scope.bats`: error paths — unknown verb (exit 2), unknown mode value (exit 2), too many args (exit 2), missing config (exit 1), missing jq (exit 1; simulated by PATH override).
- [ ] Byte-diff assertions on the config file: unrelated keys are preserved verbatim.
- [ ] `shellcheck` clean on all new/modified scripts.

**Notes**: Scratch-`$HOME` pattern from `tests/unit/vault-toggle.bats` is the template.

### T014: Integration tests — hooks honor scope, mid-session immunity, doctor probe

**File(s)**: `tests/integration/vault-rag-scope.bats` (new), `tests/integration/vault-distill-scope.bats` (new), `tests/integration/doctor-scope.bats` (new)
**Type**: Create
**Depends**: T006, T008, T009
**Acceptance**:
- [ ] `vault-rag-scope.bats`: scratch vault with a note matching the prompt keyword; scope-excluded project → `vault-rag.sh` stdout contains no `<vault-context>`; control run without exclusion emits `<vault-context>` as expected.
- [ ] `vault-rag-scope.bats`: allowlist mode + project in allowlist → emits `<vault-context>`; project NOT in allowlist → empty stdout.
- [ ] `vault-distill-scope.bats`: pre-write a snapshot `excluded` for a fake session_id; run `vault-distill.sh` with a matching payload; assert no file under `sessions/<slug>/` and the snapshot file is removed after.
- [ ] `vault-distill-scope.bats`: snapshot `all` + live config that now says excluded (simulates mid-session edit); assert distillation proceeds per the snapshot (AC6).
- [ ] `vault-distill-scope.bats`: no snapshot present; live config excludes; assert distillation is skipped (fallback branch).
- [ ] `doctor-scope.bats`: default config → human output contains `scope_mode`, `all (unscoped)`; `--json` contains `"scope_mode": {"status": "info", "note": "all (unscoped)"}`.
- [ ] `doctor-scope.bats`: `mode=allowlist` with 1 allowed, 0 excluded → human output `allowlist (excluded: 0, allowed: 1)`.
- [ ] Integration tests use the scratch-`$HOME` + scratch-vault harness; exit 0 means pass.

**Notes**: Covers the RAG overhead SLO (< 20 ms p95 when excluded) implicitly — if the gate is correctly wired, no retrieval work runs.

---

## Dependency Graph

```
T001 (om_slug cap) ──┬──▶ T003 (helpers) ──┬──▶ T004 (vault-scope.sh) ──▶ T007 (scope SKILL.md)
                     │                      │           │
                     │                      │           └──▶ T013 (unit tests)
                     │                      │
                     │                      ├──▶ T005 (vault-session-start.sh) ──▶ T008 (hooks.json)
                     │                      │
                     │                      ├──▶ T006 (rag + distill gates) ──┬──▶ T014 (integration)
                     │                      │                                  │
                     │                      └──▶ T009 (doctor probe) ──▶ T010 (doctor SKILL update)
                     │                                                         │
                     └─────────────────────────────────────────────────────────▶ T013 (unit tests)

T002 (setup scaffold)  — independent; can land any time before release.

T011 (gherkin) ──▶ T012 (step defs)   — T011 can be authored early but fully validated after T004/T006/T008/T009.
```

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #6 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to IMPLEMENT phase:

- [x] Each task has single responsibility
- [x] Dependencies are correctly mapped (see graph above)
- [x] Tasks can be completed independently (given dependencies)
- [x] Acceptance criteria are verifiable
- [x] File paths reference actual project structure (`scripts/`, `skills/`, `hooks/`, `tests/unit/`, `tests/integration/`, `tests/features/steps/` per `steering/structure.md`)
- [x] Test tasks are included for each layer (unit, integration, BDD)
- [x] No circular dependencies
- [x] Tasks are in logical execution order
