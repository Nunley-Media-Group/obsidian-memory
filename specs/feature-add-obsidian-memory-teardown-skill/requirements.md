# Requirements: Teardown Skill

**Issues**: #3
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user who wants to uninstall or migrate vaults
**I want** a single teardown skill that is the exact inverse of `/obsidian-memory:setup`
**So that** I can cleanly remove the plugin's footprint without hand-tracing every path setup wrote to.

---

## Background

`/obsidian-memory:setup` (issue #9, spec `feature-vault-setup/`) writes to several places during a healthy install:

- `~/.claude/obsidian-memory/config.json`
- `<vault>/claude-memory/sessions/` (created)
- `<vault>/claude-memory/projects` (symlink → `~/.claude/projects`)
- `<vault>/claude-memory/Index.md` (initialized when absent)
- Optionally registers the Obsidian Claude Code MCP server at user scope.

Removing the plugin today requires the user to `rm -rf ~/.claude/obsidian-memory/`, manually unlink `<vault>/claude-memory/projects`, decide whether to delete `<vault>/claude-memory/sessions/` (which contains their distilled memory), and manually unregister the MCP server. This is fragile, error-prone, and the sessions-deletion decision is ambiguous.

This feature adds `/obsidian-memory:teardown`: a read-mostly skill that removes the setup footprint safely. **Distilled session notes are the user's memory** — the default behavior must never delete them, and the destructive `--purge` path gates on explicit typed "yes" confirmation, not a y/N default. Path-safety gates reject any vault that does not look like something setup created.

Related context: issue #3 (this spec), issue #9 (`feature-vault-setup/` — the install path this inverts), issue #2 (`feature-doctor-health-check-skill/` — doctor should appear in teardown's failure messages for mismatched footprints).

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: Default teardown removes config and symlink, preserves distilled notes

**Given** a healthy install (config present, `<vault>/claude-memory/projects` symlink present, `<vault>/claude-memory/Index.md` present, `<vault>/claude-memory/sessions/` present)
**When** the user runs `/obsidian-memory:teardown` with no flags
**Then** `~/.claude/obsidian-memory/config.json` is deleted
**And** `<vault>/claude-memory/projects` symlink is removed
**And** `<vault>/claude-memory/sessions/` is preserved untouched
**And** `<vault>/claude-memory/Index.md` is preserved untouched
**And** the MCP server registration is left alone
**And** the skill prints exactly what it removed and what it preserved
**And** the skill exits 0

**Example**:
- Given: scratch `$HOME` with a full healthy install at `$BATS_TEST_TMPDIR/vault`
- When: `scripts/vault-teardown.sh` runs with no flags
- Then: config file is gone, symlink is gone; `sessions/` and `Index.md` are byte-identical to their pre-teardown state

### AC2: `--purge` deletes distilled notes after typed "yes" confirmation

**Given** a healthy install with N distilled session notes under `<vault>/claude-memory/sessions/`
**When** the user runs `/obsidian-memory:teardown --purge`
**Then** the skill shows a count of note files and the absolute path that would be deleted
**And** prompts for explicit confirmation (the user must type the literal string `yes`)
**And** on `yes`, deletes `<vault>/claude-memory/sessions/` and `<vault>/claude-memory/Index.md` in addition to the default removals
**And** on any other response (including `y`, `Y`, `YES`, empty line, EOF), skips the purge and reports that sessions were preserved
**And** the skill exits 0 whether the user confirmed or refused

### AC3: `--unregister-mcp` removes the MCP server registration

**Given** the Obsidian MCP server is registered at user scope (as would be produced by `/obsidian-memory:setup` when the user opted in)
**When** the user runs `/obsidian-memory:teardown --unregister-mcp`
**Then** the skill runs the inverse of the setup registration command (`claude mcp remove obsidian -s user` or the current equivalent)
**And** a successful removal is reported as removed
**And** a non-zero exit from `claude mcp remove` (not registered, `claude` not on PATH, etc.) is reported as a one-line non-fatal message and does not block the remainder of teardown
**And** the skill exits 0

### AC4: Path-safety refusal on a mismatched footprint

**Given** `~/.claude/obsidian-memory/config.json` has been edited so `vaultPath` points at a directory that does not contain a recognizable `claude-memory/` layout (i.e., `<vault>/claude-memory/` is missing, is not a directory, or `<vault>/claude-memory/projects` is not a symlink created by setup)
**When** the user runs `/obsidian-memory:teardown` (with or without flags)
**Then** the skill detects the mismatch before deleting anything
**And** prints the detected vault path, the specific mismatch, and a one-line remediation hint that mentions `/obsidian-memory:doctor` (issue #2) for diagnosis
**And** does not delete the config file, the symlink, the sessions directory, the Index.md, or anything else under the vault
**And** the skill exits non-zero

### AC5: Teardown is idempotent (nothing-to-do state)

**Given** a fully torn-down state — no `~/.claude/obsidian-memory/config.json`, no `<vault>/claude-memory/projects` symlink, no `<vault>/claude-memory/sessions/`, no `<vault>/claude-memory/Index.md`
**When** the user runs `/obsidian-memory:teardown` a second time
**Then** the skill reports that there is nothing to do (no config found) with no errors
**And** no file is created, modified, or deleted anywhere
**And** the skill exits 0

**Example**:
- Given: scratch `$HOME` with no `~/.claude/obsidian-memory/` at all
- When: `scripts/vault-teardown.sh` runs
- Then: stdout contains "nothing to do" (or equivalent phrasing); exit code is 0

### AC6: `--dry-run` prints what would be removed without touching anything

**Given** a healthy install
**When** the user runs `/obsidian-memory:teardown --dry-run` (or `/obsidian-memory:teardown --purge --dry-run`)
**Then** the skill prints a plan listing every path that would be removed and every path that would be preserved
**And** no file is created, modified, or deleted
**And** no MCP command is invoked (even if `--unregister-mcp` is also passed)
**And** the skill exits 0

### Generated Gherkin Preview

See [feature.gherkin](feature.gherkin) for the canonical BDD scenarios.

```gherkin
Feature: Teardown inverts obsidian-memory setup safely
  As a Claude Code + Obsidian user who wants to uninstall or migrate vaults
  I want a single teardown skill that is the exact inverse of /obsidian-memory:setup
  So that I can cleanly remove the plugin's footprint without hand-tracing every path setup wrote to

  Scenario: Default teardown removes config and symlink, preserves distilled notes
    Given a baseline-healthy obsidian-memory install
    When  I run "/obsidian-memory:teardown"
    Then  the config file is removed
    And   the projects symlink is removed
    And   the sessions directory is preserved
    And   the Index.md is preserved
    And   the teardown exit code is 0

  # ... all ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Add `skills/teardown/SKILL.md` following the skill template in `steering/structure.md`. | Must | Issue #3 body mentions `plugins/obsidian-memory/skills/teardown/SKILL.md`; this repo is a standalone plugin, so skills live at `skills/` (see `structure.md` → Project Layout). |
| FR2 | Implement teardown logic as a shell script under `scripts/` so bats can exercise every code path without invoking Claude. | Must | Mirrors the doctor pattern (SKILL.md delegates to a script). |
| FR3 | Default behavior: remove config + symlink; preserve sessions + Index.md; leave MCP registration alone. | Must | Core inverse-of-setup contract. |
| FR4 | `--purge` flag: after the default removals, additionally delete `sessions/` and `Index.md` only if the user types the literal string `yes` at the confirmation prompt. | Must | Exact string match on `yes`; any other input (including `y`, `YES`, empty, EOF) aborts the purge. |
| FR5 | `--unregister-mcp` flag: inverse of setup's MCP registration. Non-zero exits from the underlying `claude mcp` command are reported as non-fatal. | Must | Uses `claude mcp remove obsidian -s user` (or current equivalent). |
| FR6 | Path-safety check before any deletion: verify `<vault>/claude-memory/` exists as a directory and (at least) the `projects` symlink resolves to `~/.claude/projects` *or* is absent. If the layout is mismatched, refuse and exit non-zero. | Must | Prevents the "user edited config to point at an unrelated directory" class of accidents. |
| FR7 | Idempotent — running teardown twice must be safe. Missing config is the "nothing to do" signal. | Must | Matches setup's idempotent property from `steering/product.md`. |
| FR8 | BDD scenarios for: default teardown, `--purge` with `yes`, `--purge` with refusal, `--unregister-mcp`, mismatched footprint, double-teardown (idempotency), `--dry-run`. | Must | Lives at `specs/feature-add-obsidian-memory-teardown-skill/feature.gherkin`. |
| FR9 | `--dry-run` flag printing what would be removed without touching anything. | Should | Combines with other flags (e.g., `--purge --dry-run` still prints both groups and touches nothing). |
| FR10 | Output vocabulary is consistent with `/obsidian-memory:setup` and `/obsidian-memory:doctor` ("vault path", "config", "projects symlink", "sessions directory", "Index.md"). | Should | Reduces cognitive load across skills. |
| FR11 | Exit codes: `0` on a successful teardown (including idempotent nothing-to-do, purge refusal, and dry-run); non-zero on bad args or path-safety refusal. | Must | Matches doctor's pattern: `1` on refuse, `2` on usage errors. |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Wall time < 500 ms in the common case; no network calls; no `claude -p` subprocess. `claude mcp remove` may add wall time in the `--unregister-mcp` path but is bounded by a `timeout 3` like doctor's MCP probe. |
| **Security** | Only `unlink`, `rm -r` under the vault's `claude-memory/` subtree, and `rm` of the config file. No paths are accepted from invocation flags — the vault path comes from `config.json`. No `rm` accepts a relative path. All deletions are absolute and inside the verified `<vault>/claude-memory/` subtree or `~/.claude/obsidian-memory/`. |
| **Accessibility** | Plain-text output works in every terminal. Color is an enhancement, not a requirement. |
| **Reliability** | Teardown itself must never accidentally delete the user's notes. The path-safety gate (FR6) and the typed-`yes` gate (FR4) are the load-bearing safeguards — both must be in place before any deletion runs. |
| **Platforms** | macOS default bash (3.2) and Linux bash 4+, per `steering/tech.md`. Uses only POSIX `rm`, `unlink`, `readlink` (no `-f`), and `test` — no GNU extensions. |

---

## UI/UX Requirements

Teardown has no GUI. Its "UI" is terminal output and one confirmation prompt.

| Element | Requirement |
|---------|-------------|
| **Structure** | Plan section (what will be removed / preserved) → optional confirmation prompt → action section (what actually happened) → summary line. |
| **Confirmation prompt** | Only present for `--purge`. Exactly one prompt. Exact string match on `yes` — case-sensitive, no default. Reads from stdin; EOF is treated as refusal. |
| **Vocabulary** | Reuse terms from `setup` and `doctor` ("vault path", "config", "projects symlink", "sessions directory", "Index.md"). |
| **Color (TTY only)** | Status words color-coded (REMOVED red, PRESERVED green, WOULD REMOVE / WOULD PRESERVE yellow in dry-run, REFUSED bold red). Never colorize when `stdout` is piped. |
| **Empty state** | The idempotent nothing-to-do state prints a single line ("no obsidian-memory config found — nothing to do") and exits 0. |
| **Error state** | Path-safety refusal prints the detected vault path, the specific mismatch, and a hint referencing `/obsidian-memory:doctor`. |

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `--purge` flag | CLI flag | Presence only | No |
| `--unregister-mcp` flag | CLI flag | Presence only | No |
| `--dry-run` flag | CLI flag | Presence only | No |
| stdin (purge confirmation) | string | Exact match on `yes` | Only when `--purge` is set and `--dry-run` is not |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| stdout | plain text | Plan + actions + summary; ANSI-colored on TTY, plain when piped |
| Exit code | int | 0 on success (including idempotent and dry-run); 1 on path-safety refusal; 2 on bad usage |

---

## Dependencies

### Internal Dependencies

- [x] `/obsidian-memory:setup` — teardown inverts what setup did; vocabulary and paths must stay in lockstep
- [x] `/obsidian-memory:doctor` (issue #2) — referenced in the path-safety failure hint so users get a clear remediation path
- [x] `scripts/_common.sh` — **not** used at runtime (teardown reads the config directly for the same reason doctor does; see design Alternatives)

### External Dependencies

- [x] `jq` — required for reading `vaultPath` out of `config.json`. Missing `jq` produces a path-safety refusal with a hint to install `jq`.
- [x] `claude` CLI — required only for the `--unregister-mcp` path. Missing `claude` on that path is reported non-fatally.

### Blocked By

- None. Issue #1 (bats-core + cucumber-shell harness) and issue #2 (doctor) are already shipped.

---

## Out of Scope

- **Uninstalling the plugin itself from Claude Code.** That is `claude plugin uninstall obsidian-memory` and lives outside this plugin.
- **Migrating sessions to a new vault.** Tracked separately if needed.
- **Automatic teardown on setup-with-different-vault.** Setup's responsibility is its own; teardown is a deliberate user action.
- **Deleting the vault itself.** Teardown only touches `<vault>/claude-memory/` and `~/.claude/obsidian-memory/`. The vault directory is user-owned.
- **Restoring or recovering distilled notes after `--purge`.** There is no undo. This is why `--purge` requires a typed `yes`.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| User-owned data preservation | 100% — no regression test ever records a deleted sessions/ or Index.md under default teardown | Integration test asserts sessions/ and Index.md contents are byte-identical pre/post default teardown |
| Path-safety catches | 100% of the mismatched-footprint scenarios in AC4 refuse before any deletion | Integration test per mismatch variant |
| Typed-`yes` discipline | 100% — any input other than literal `yes` aborts the purge | Parameterized bats test with `y`, `Y`, `YES`, empty, EOF, `yes\n` all produce the correct outcomes |
| Idempotency | Running teardown twice produces no errors and no filesystem changes on the second run | Integration test runs teardown twice and asserts the second run is a no-op |

---

## Open Questions

- [x] Should the purge prompt be case-insensitive? — **Resolved: no.** Case-sensitive literal `yes` is the spec. Distilled sessions are durable memory; an accidental `Y` must not delete them.
- [x] Should `--dry-run` also work with `--unregister-mcp`? — **Resolved: yes.** `--dry-run` suppresses every side effect, including the MCP command.
- [x] Should teardown remove an empty `<vault>/claude-memory/` directory after default teardown? — **Resolved: no.** If the default run preserves `sessions/` and `Index.md`, the parent is non-empty by definition. If they were separately removed (via `--purge`), teardown may `rmdir` the parent only if it is empty; otherwise leave it alone.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #3 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to PLAN phase:

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements (design.md will cover how)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases (path mismatch, idempotency, dry-run, EOF on confirmation) are specified
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented and resolved
