# Tasks: Teardown Skill

**Issues**: #3
**Date**: 2026-04-21
**Status**: Planning
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 1 | [ ] |
| Backend | 3 | [ ] |
| Integration | 1 | [ ] |
| Testing | 3 | [ ] |
| **Total** | 8 | |

"Backend" means the shell script implementation; "Integration" means the user-facing skill wrapper.

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

**File(s)**: `skills/teardown/`, `scripts/`, `tests/integration/`, `tests/features/steps/`
**Type**: Create (directories only; actual files created in later tasks)
**Depends**: None
**Acceptance**:
- [ ] `skills/teardown/` exists (empty, ready for SKILL.md in T005)
- [ ] `scripts/`, `tests/integration/`, `tests/features/steps/` already exist from prior work — verify presence, create if missing
- [ ] No existing files overwritten

**Notes**: Low-risk directory prep task. Combines creation with presence verification so the task is safely idempotent. Mirrors the setup used in `feature-doctor-health-check-skill/tasks.md` T001.

---

## Phase 2: Backend Implementation

### T002: Implement `vault-teardown.sh` core (discover, validate, plan, default act)

**File(s)**: `scripts/vault-teardown.sh`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] Shebang `#!/usr/bin/env bash`; `set -u`; `trap` at top level per `steering/tech.md` Bash standards
- [ ] Parses `--purge`, `--unregister-mcp`, `--dry-run` flags; anything else prints a usage line and exits 2
- [ ] **Stage 1 (discover)**: reads `$HOME/.claude/obsidian-memory/config.json`; if missing, prints `"no obsidian-memory config found — nothing to do"` and exits 0
- [ ] **Stage 1**: uses `jq` to parse `.vaultPath`; missing/null → falls through to path-safety refusal in Stage 2
- [ ] **Stage 2 (path-safety gate)** implements validators V1–V4 from `design.md` → Data Flow:
  - V1 `<vault>` is an existing directory
  - V2 `<vault>/claude-memory/` is an existing directory
  - V3 `<vault>/claude-memory/projects` is either a symlink resolving (via plain `readlink`, no `-f`) to `$HOME/.claude/projects`, or absent
  - V4 `jq` is available
- [ ] Any V1–V4 failure → print detected vault path, specific mismatch, and remediation hint referencing `/obsidian-memory:doctor`; exit 1
- [ ] **Stage 3 (plan)**: populates `PLAN_REMOVE` and `PLAN_PRESERVE` bash arrays per `design.md` → Data Flow step 5
- [ ] **Stage 4 (default act)**: `unlink` the projects symlink (if present), then `rm -f` the config file; `rmdir` `~/.claude/obsidian-memory` and `<vault>/claude-memory` only if empty, swallowing failures
- [ ] Every `rm`/`unlink` target is an absolute path that was already validated in Stage 2 — no relative paths, no unset-variable expansions
- [ ] Human output format matches the samples in `design.md` → Human-mode output format (default teardown and refusal samples)
- [ ] ANSI color codes emitted only when `[ -t 1 ]`
- [ ] Exits 0 on a successful default teardown
- [ ] Passes `shellcheck scripts/vault-teardown.sh`

**Notes**: Do NOT reuse `scripts/_common.sh::om_load_config` — it exits 0 on any failure, which masks the diagnoses teardown must surface. Teardown reads the config directly, same rationale as doctor (see Alternatives Considered Option E in `design.md`). The destructive boundary MUST NOT be crossed before Stage 2 returns OK — this is the single load-bearing safety property.

### T003: Add `--purge` flow with typed-`yes` confirmation

**File(s)**: `scripts/vault-teardown.sh` (extends T002)
**Type**: Modify
**Depends**: T002
**Acceptance**:
- [ ] When `--purge` is passed (and `--dry-run` is not), Stage 3b prompts on stderr: `"About to delete N distilled note file(s) under <abs-path>."` then `"Type 'yes' to confirm (anything else cancels): "`
- [ ] Reads exactly one line from stdin via `read -r REPLY` (no timeout)
- [ ] Accepts the purge only when `[ "$REPLY" = "yes" ]` — case-sensitive exact match on the literal string `yes`
- [ ] `y`, `Y`, `YES`, empty line, EOF, and any other input cancel the purge
- [ ] On cancel: `sessions/` and `Index.md` are moved from `PLAN_REMOVE` back into `PLAN_PRESERVE`; prints `"Sessions preserved — purge cancelled."`
- [ ] On confirm: `rm -rf "<vault>/claude-memory/sessions"` and `rm -f "<vault>/claude-memory/Index.md"` run between the symlink removal and the config removal
- [ ] The confirmation is reached only after Stage 2 returned OK — a path-safety refusal must never run the prompt
- [ ] Exits 0 whether the purge confirmed or cancelled
- [ ] Passes `shellcheck scripts/vault-teardown.sh`

**Notes**: Do not add a `-y`/`--yes` flag that bypasses the prompt — explicitly rejected in `design.md` → Alternatives Considered Option D. Anyone who needs unattended purge can delete the plain-Markdown notes directly.

### T004: Add `--unregister-mcp` flow and `--dry-run` flag

**File(s)**: `scripts/vault-teardown.sh` (extends T002 and T003)
**Type**: Modify
**Depends**: T002, T003
**Acceptance**:
- [ ] `--unregister-mcp`: after Stage 4, runs `timeout 3 claude mcp remove obsidian -s user` (matches the inverse of `/obsidian-memory:setup` Step 5's registration command)
- [ ] A non-zero exit or timeout from the MCP command is treated as non-fatal: prints a one-line warning; teardown exit code stays 0
- [ ] If `claude` is not on PATH, prints the same non-fatal warning (no crash)
- [ ] `--dry-run`: after Stage 3 (plan), prints the plan with `WOULD REMOVE:` / `WOULD PRESERVE:` labels, then exits 0. Does NOT prompt. Does NOT invoke any `rm`/`unlink`/`rmdir`. Does NOT invoke `claude mcp remove` (even when combined with `--unregister-mcp`)
- [ ] `--dry-run` combined with `--purge` includes `sessions/` and `Index.md` under WOULD REMOVE without prompting
- [ ] Human output matches the purge/cancelled/refusal samples in `design.md` → Human-mode output format
- [ ] Exit code policy from `design.md` → Exit code contract is enforced across every flag combination
- [ ] Passes `shellcheck scripts/vault-teardown.sh`

**Notes**: Wrap the MCP command in `timeout 3` exactly as `scripts/vault-doctor.sh` does for its MCP probe, so the skill is never slow on a machine where `claude` is misbehaving.

---

## Phase 3: Integration

### T005: Write `skills/teardown/SKILL.md`

**File(s)**: `skills/teardown/SKILL.md`
**Type**: Create
**Depends**: T002, T003, T004
**Acceptance**:
- [ ] Frontmatter follows the template in `steering/structure.md` → File Templates → Skill template
- [ ] `name: teardown`; `description:` includes trigger phrases ("uninstall obsidian memory", "remove obsidian-memory", "tear down obsidian memory", "inverse of setup", "/obsidian-memory:teardown")
- [ ] `allowed-tools: Bash, Read` (no Write/Edit — the script performs deletions; the skill is a thin relayer)
- [ ] `model: sonnet`, `effort: low` (matches `setup` and `doctor`)
- [ ] Body documents the three flags (`--purge`, `--unregister-mcp`, `--dry-run`), the typed-`yes` guarantee, the path-safety guarantee, and the exit code contract
- [ ] "When to Use" and "When NOT to Use" sections present; "When NOT to Use" calls out `claude plugin uninstall obsidian-memory` and vault migration as explicitly out of scope
- [ ] Instructs Claude to invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-teardown.sh"` (with `"$@"`), relay the script's exit code and output verbatim, and never call the script twice in one invocation
- [ ] Mentions that `--purge` is destructive and not reversible, and that distilled notes are plain Markdown the user can also delete manually if they prefer
- [ ] Cross-links to `/obsidian-memory:doctor` in the path-safety refusal hint and to `/obsidian-memory:setup` in the Related Skills section

**Notes**: The SKILL.md is intentionally thin — Claude shells out to the script and reports back, no re-interpretation of results. This preserves the bats-testable contract for the underlying logic.

---

## Phase 5: BDD Testing (Required)

**Every acceptance criterion MUST have a Gherkin scenario.**

### T006: Write BDD feature file

**File(s)**: `specs/feature-add-obsidian-memory-teardown-skill/feature.gherkin`
**Type**: Create
**Depends**: None (can be drafted in parallel with T002)
**Acceptance**:
- [ ] One or more scenarios per AC from `requirements.md`:
  - AC1 → `Scenario: Default teardown removes config and symlink, preserves distilled notes`
  - AC2 → `Scenario: Purge with typed 'yes' deletes distilled notes` plus one cancellation scenario per representative rejection input (`y`, `YES`, empty, EOF)
  - AC3 → `Scenario: --unregister-mcp removes the MCP server registration` plus one non-fatal-failure scenario
  - AC4 → at least three mismatch variants (no `claude-memory/`, projects is not a symlink, symlink points elsewhere)
  - AC5 → `Scenario: Double teardown is a no-op` and `Scenario: Teardown with no config is a no-op`
  - AC6 → `Scenario: --dry-run on a healthy install touches nothing` and `Scenario: --dry-run --purge lists sessions without prompting`
- [ ] Uses a `Background:` block declaring the scratch `$HOME` harness so every scenario runs under `tests/helpers/scratch.bash` — mirrors the pattern in `feature-doctor-health-check-skill/feature.gherkin`
- [ ] Valid Gherkin syntax — `tests/run-bdd.sh` parses the file without error
- [ ] Uses declarative phrasing ("I run /obsidian-memory:teardown"), not implementation details
- [ ] No `Scenario Outline:` (not supported by `tests/run-bdd.sh` — each variant is its own explicit scenario)

### T007: Implement step definitions

**File(s)**: `tests/features/steps/teardown.sh`
**Type**: Create
**Depends**: T002, T003, T004, T006
**Acceptance**:
- [ ] One step definition per unique Given/When/Then phrase in `feature.gherkin`
- [ ] Step definitions follow the naming convention in `steering/tech.md` → Step Definitions (function name mirrors the step phrasing, `lower_snake_case`)
- [ ] All filesystem state lives under `$BATS_TEST_TMPDIR` per the scratch harness contract
- [ ] Invokes the script under test via `"$PLUGIN_ROOT/scripts/vault-teardown.sh"`
- [ ] Purge confirmation inputs (`yes`, `y`, `YES`, empty, EOF) are supplied via process stdin (e.g., `printf '%s\n' yes | vault-teardown.sh --purge`)
- [ ] MCP command is stubbed via `tests/helpers/fake-claude.bash` (or a shim in the scratch `PATH`) — never invokes the user's real `claude`
- [ ] `tests/run-bdd.sh` passes with every scenario green
- [ ] Passes `shellcheck tests/features/steps/teardown.sh`

### T008: Add bats integration test

**File(s)**: `tests/integration/teardown.bats`, plus a new `assert_sessions_untouched` helper in `tests/helpers/scratch.bash`
**Type**: Create (teardown.bats) + Modify (scratch.bash)
**Depends**: T002, T003, T004
**Acceptance**:
- [ ] `setup()` loads `../helpers/scratch`, materializes a baseline-healthy install (config, symlink, `sessions/` with N fake notes, `Index.md`), and snapshots a cksum digest of `sessions/` + `Index.md` for `assert_sessions_untouched`
- [ ] `teardown()` calls `assert_sessions_untouched` on every test EXCEPT the `--purge --yes` and double-teardown-after-purge cases
- [ ] One `@test` per row of the test matrix in `design.md` → Testing Strategy (happy_default, purge_yes, purge_y, purge_cap_YES, purge_empty, purge_eof, unregister_mcp_ok, unregister_mcp_fail, refuse_no_claude_memory, refuse_projects_not_symlink, refuse_projects_wrong_target, refuse_vault_missing, idempotent_no_config, idempotent_after_default, dry_run_healthy, dry_run_purge, dry_run_unregister) — 17 tests total
- [ ] Each refuse_* test asserts exit code 1, a `REFUSED` line in stdout, and the post-test existence of the config, symlink, `sessions/`, and `Index.md` (none deleted)
- [ ] Each dry_run_* test asserts exit code 0 and byte-identical pre/post filesystem state (including the config, symlink, sessions, and Index.md)
- [ ] The purge_yes test is the ONLY test whose post-state deletes `sessions/` and `Index.md`
- [ ] `bats tests/integration/teardown.bats` passes
- [ ] `tests/helpers/scratch.bash` `assert_sessions_untouched` helper uses the same cksum-digest pattern as `assert_home_untouched`

**Notes**: The purge cancellation variants (`y`, `YES`, empty, EOF) are the most subtle branch — parameterize them as separate `@test` functions rather than looping, so bats reports each input on its own line. Stub `claude` in the scratch `PATH` for the two `--unregister-mcp` variants; for `unregister_mcp_fail` use a stub that `exit 1`s deterministically.

---

## Dependency Graph

```
T001 ──┬──▶ T002 ──▶ T003 ──▶ T004 ──┬──▶ T005
       │                              │
       │                              └──▶ T008
       │
       └──▶ T006 ──▶ T007 (also depends on T004)
```

Critical path: T001 → T002 → T003 → T004 → T005 (skill surface reaches the user).
Independent track: T006 can start as soon as requirements.md is approved; T007 joins once T006 and T004 both land; T008 joins once T004 lands.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #3 | 2026-04-21 | Initial feature spec |

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
- [x] Destructive-path tasks explicitly call out the load-bearing safety invariants (path-safety gate, typed-`yes` gate)
