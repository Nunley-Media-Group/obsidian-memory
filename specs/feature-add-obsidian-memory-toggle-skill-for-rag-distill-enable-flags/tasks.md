# Tasks: Toggle Skill for rag/distill Enable Flags

**Issues**: #4
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

"Backend" is the shell implementation. "Integration" is the user-facing skill wrapper and doctor cross-reference verification.

This feature has no Frontend phase — obsidian-memory is a CLI plugin with no UI components (per `steering/structure.md` → "Design Tokens / UI Standards: Not applicable").

---

## Task Format

```
### T[NNN]: [Task Title]

**File(s)**: `path/to/file`
**Type**: Create | Modify | Verify
**Depends**: T[NNN] (or None)
**Acceptance**:
- [ ] [Verifiable criterion]
```

---

## Phase 1: Setup

### T001: Create feature directory structure

**File(s)**: `skills/toggle/`, `tests/integration/`, `tests/features/steps/`
**Type**: Create (directories only; actual files created in later tasks)
**Depends**: None
**Acceptance**:
- [ ] `skills/toggle/` exists (empty, ready for SKILL.md in T004)
- [ ] `tests/integration/` and `tests/features/steps/` already exist from prior work — verify presence, create if missing
- [ ] `scripts/` already exists (contains `_common.sh`, `vault-rag.sh`, `vault-distill.sh`, `vault-doctor.sh`, `vault-teardown.sh`) — verify only

**Notes**: Idempotent directory prep. No new test dirs are needed — existing harness directories are reused.

---

## Phase 2: Backend Implementation

### T002: Implement `vault-toggle.sh`

**File(s)**: `scripts/vault-toggle.sh`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Shebang `#!/usr/bin/env bash`; `set -u`; `trap` at top level per `steering/tech.md` Bash standards
- [ ] Top-level `trap 'rm -f "$TMP" 2>/dev/null || true' EXIT` — cleans any temp-file droppings on exit
- [ ] Does **NOT** source `_common.sh::om_load_config` — rationale captured in `design.md` → Alternatives Considered → Option B
- [ ] Reads `$HOME/.claude/obsidian-memory/config.json` directly
- [ ] Arg parsing implements the full CLI grammar from `design.md` → API:
  - 0 args → mode=status
  - 1 arg == `status` → mode=status
  - 1 arg (any `<feature>`) → mode=flip
  - 2 args (`<feature>`, `<state>`) → mode=set
  - 3+ args → usage on stderr + exit 2
- [ ] Feature whitelist enforced: any feature not in `{rag, distill}` → `ERROR: unknown feature '<arg>' — allowed: rag, distill` on stderr + exit 2
- [ ] State alias table enforced (case-insensitive):
  - `on`, `true`, `1`, `yes` → `true`
  - `off`, `false`, `0`, `no` → `false`
  - Anything else → `ERROR: unknown state …` on stderr + exit 2
- [ ] Missing config → `ERROR: config not found — run /obsidian-memory:setup <vault> first` on stderr + exit 1
- [ ] Missing `jq` → `ERROR: jq missing — install jq (brew install jq)` on stderr + exit 1
- [ ] Status mode reads `.rag.enabled` and `.distill.enabled` via jq; prints two lines `rag.enabled: <bool>` and `distill.enabled: <bool>`; exit 0
- [ ] Unset feature stanza normalizes to `true` for reporting (matches `_common.sh` semantics — see `design.md` → Risks → "missing feature stanza")
- [ ] Mutation uses atomic write: `jq --indent 2 --argjson v <bool> '.<feature>.enabled = $v' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"`
- [ ] `$TMP` lives in the same directory as `$CONFIG` (`"$CONFIG.tmp.$$"`), never under `/tmp`
- [ ] On mutation success, prints `<feature>.enabled: <prev> -> <new>` on stdout + exit 0
- [ ] On flip (no explicit state), computes the inverse of the current value before the write
- [ ] On "already in state" (explicit set equals current), prints `<feature>.enabled was already <value>` on stdout + exit 0 **without rewriting** the config file (mtime and inode unchanged)
- [ ] Error first line on stderr always starts with literal `ERROR:` (per FR-level convention in `design.md`)
- [ ] Passes `shellcheck scripts/vault-toggle.sh`
- [ ] Script is chmod +x

**Notes**: Reference `scripts/vault-doctor.sh` for the "user-invoked, errors must surface" style and `scripts/vault-teardown.sh` for the atomic-write / trap-based cleanup idiom. The `--argjson` form is required so `jq` parses the boolean as a JSON literal rather than a string.

### T003: Verify key-preservation behavior

**File(s)**: `scripts/vault-toggle.sh` (same script as T002)
**Type**: Verify (no new file)
**Depends**: T002
**Acceptance**:
- [ ] A config containing unrelated user-added keys (e.g., `"customFoo": 42`) round-trips every key byte-for-byte after a toggle
- [ ] A config written by `/obsidian-memory:setup` (2-space indent, specific key order) retains its formatting after a toggle — no diff other than the flipped boolean
- [ ] A config where the feature stanza is absent (e.g., no `"distill"` key at all) gets the stanza auto-created by `jq` when the user runs `toggle distill on`; other keys are still preserved

**Notes**: This is a gate, not a new implementation task — it verifies the `jq --indent 2` + whole-document round-trip chosen in `design.md` → Key-preservation rules. Tests from Phase 3 exercise all three cases; T003 closes when those tests are green.

---

## Phase 3: Integration

### T004: Write the `toggle` SKILL.md

**File(s)**: `skills/toggle/SKILL.md`
**Type**: Create
**Depends**: T002
**Acceptance**:
- [ ] Frontmatter matches the shape in `design.md` → New: `skills/toggle/SKILL.md`:
  - `name: toggle`
  - `description:` includes trigger phrases ("disable rag", "enable distill", "turn off obsidian memory hook", "toggle rag", "/obsidian-memory:toggle")
  - `argument-hint: [<feature> [<state>]]`
  - `allowed-tools: Bash, Read`
  - `model: sonnet`
  - `effort: low`
- [ ] Body sections present: one-paragraph summary, **When to Use**, **When NOT to Use**, **Invocation**, **Behavior** (relay only), **Exit Code Contract**, **Error Handling**, **Idempotency**, **Related skills** — mirrors the section list in `skills/doctor/SKILL.md`
- [ ] Behavior section explicitly instructs Claude to invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-toggle.sh" "$@"` and to **relay the script's stdout and exit code verbatim** — do not re-interpret, do not re-run
- [ ] Exit Code Contract table lists `0`, `1`, `2` with the semantics from `design.md`
- [ ] Related skills section cross-references `/obsidian-memory:setup` (prerequisite for the config), `/obsidian-memory:doctor` (diagnoses + links back to toggle), and `/obsidian-memory:distill-session` (alternative to "disable distill" if the user only wants to skip one session)

**Notes**: No logic in the SKILL body. Every code path is in the script. Matches `skills/doctor/SKILL.md` and `skills/teardown/SKILL.md` precisely.

---

## Phase 4: BDD Testing (Required)

### T005: Write the Gherkin feature file

**File(s)**: `specs/feature-add-obsidian-memory-toggle-skill-for-rag-distill-enable-flags/feature.gherkin`
**Type**: Create (supplied alongside this tasks.md)
**Depends**: T002
**Acceptance**:
- [ ] One scenario per AC1–AC7 from `requirements.md`
- [ ] AC8 is a `Scenario Outline` with the alias table as Examples
- [ ] Uses Given/When/Then format per `tech.md` → BDD Testing
- [ ] Valid Gherkin syntax (parses with the `tests/run-bdd.sh` runner)

**Notes**: The file is created alongside this tasks.md so it is reviewable at spec time. T006 implements the step definitions it calls.

### T006: Implement step definitions for the Gherkin scenarios

**File(s)**: `tests/features/steps/toggle.sh`
**Type**: Create
**Depends**: T002, T005
**Acceptance**:
- [ ] One step-definition function per unique Given/When/Then phrase in the feature file
- [ ] Given-step helpers write scratch config to `$HOME/.claude/obsidian-memory/config.json` under the scratch harness (`tests/helpers/scratch.bash` already redirects `$HOME`)
- [ ] When-step helpers invoke `"$PLUGIN_ROOT/scripts/vault-toggle.sh"` with the tested argv and capture stdout, stderr, exit code into per-scenario vars
- [ ] Then-step helpers assert against the captured output and re-read the config back to assert persisted state
- [ ] Follows the naming / structure conventions in `tests/features/steps/doctor.sh` and `tests/features/steps/teardown.sh`
- [ ] Runs under `tests/run-bdd.sh`; exits 0

### T007: Write bats integration tests for `vault-toggle.sh`

**File(s)**: `tests/integration/toggle.bats`
**Type**: Create
**Depends**: T002
**Acceptance**:
- [ ] `setup()` loads `../helpers/scratch` and sets `TOGGLE="$PLUGIN_ROOT/scripts/vault-toggle.sh"`
- [ ] Each case below is a distinct `@test`:
  1. status prints both flags (happy path)
  2. status-shorthand (no args) equivalent to explicit `status`
  3. `rag off` flips true → false, persists to disk, exit 0
  4. `rag on` on already-true reports "was already" + exit 0 + mtime/inode unchanged (assert via `stat`)
  5. `distill` (no state) flips the current value
  6. `foobar on` prints `ERROR: unknown feature` to stderr + exit 2 + config unchanged
  7. `rag maybe` prints `ERROR: unknown state` to stderr + exit 2 + config unchanged
  8. Missing config → `ERROR: config not found` to stderr + exit 1 + no file created
  9. Unrelated user keys (`customFoo: 42`) survive a toggle byte-for-byte (assert with `diff`/`jq`)
  10. Missing feature stanza (no `distill` key at all) — `toggle distill on` creates the stanza; other keys preserved
  11. Atomic-write invariant: forcibly delete the `.tmp.$$` file *before* mv via a wedge (e.g., stub the `mv` call to fail) and confirm original config is untouched (covers the "mv failed" branch — requires driving the script with `PATH` pointing at a `mv` stub in `$BATS_TEST_TMPDIR/bin/`)
  12. Shellcheck gate (`shellcheck scripts/vault-toggle.sh` returns 0)
- [ ] `teardown()` calls `assert_home_untouched` — proves the real `~/.claude/obsidian-memory/` was never mutated during the run

**Notes**: The test for case 11 is the strongest guarantee of the AC6 atomic-write invariant. Use the same PATH-stub pattern that `tests/integration/teardown.bats` uses for its `claude mcp remove` stub.

---

## Dependency Graph

```
T001 ──▶ T002 ──┬──▶ T003 (verify key preservation)
                ├──▶ T004 (SKILL.md)
                ├──▶ T005 (gherkin)──▶ T006 (steps)
                └──▶ T007 (bats)
```

Critical path: **T001 → T002 → T007** (the atomic-write test is the last thing to go green and the highest-risk assertion).

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #4 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to IMPLEMENT phase:

- [x] Each task has single responsibility
- [x] Dependencies are correctly mapped
- [x] Tasks can be completed independently (given dependencies)
- [x] Acceptance criteria are verifiable
- [x] File paths reference actual project structure (per `steering/structure.md`)
- [x] Test tasks are included for each layer (shellcheck + bats + BDD)
- [x] No circular dependencies
- [x] Tasks are in logical execution order
