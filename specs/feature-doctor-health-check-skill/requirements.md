# Requirements: Doctor Health-Check Skill

**Issues**: #2
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user who just installed obsidian-memory
**I want** a one-command health check that tells me whether my install is actually working
**So that** silent hook no-ops do not leave me believing memory is flowing when it isn't

---

## Background

The core safety principle of this plugin (`steering/product.md` → Product Principles → "Silent failure") is that every hook exits 0 on any failure mode: missing `jq`, missing `ripgrep`, missing config, disabled flag, empty input. This is deliberate — a blocking hook destroys user trust. But the same silence makes broken installs invisible: a user can install the plugin, forget to run `/obsidian-memory:setup`, and never realize their sessions are not being distilled or that their prompts are not being RAG-enriched.

A dedicated `doctor` skill exposes that install state on demand, without changing the hooks' silent-on-failure behavior. The skill is a **read-only reporter** — it detects problems and prints remediation hints, but it never mutates the config, the vault, or the `~/.claude/projects/` symlink. Fixing is the job of `/obsidian-memory:setup` (already shipping) and `/obsidian-memory:toggle` (tracked as a separate v1 issue).

Related context: issue #2, issue #1 (bats-core + cucumber-shell harness that this skill's tests run on).

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: Doctor passes on a healthy install

**Given** `~/.claude/obsidian-memory/config.json` exists with a valid `vaultPath` pointing at a real directory
**And** `jq` is on `PATH` and `claude` is on `PATH`
**And** `<vault>/claude-memory/sessions/` exists and `<vault>/claude-memory/projects` is a symlink resolving to `~/.claude/projects`
**And** `rag.enabled` and `distill.enabled` are `true` (or unset, which the scripts treat as enabled)
**When** the user runs `/obsidian-memory:doctor`
**Then** the skill reports `OK` for every check with a green-style summary line
**And** the skill exits 0

**Example**:
- Given: scratch `$HOME` with a valid config pointing at `$BATS_TEST_TMPDIR/vault`, which contains `claude-memory/sessions/` and a valid `claude-memory/projects` symlink
- When: the doctor script is invoked
- Then: stdout shows one `OK` line per check and a final `All checks passed.` summary; exit code is 0

### AC2: Doctor reports each specific failure mode with a one-line remediation hint

**Given** one of the failure modes below is in effect
**When** the user runs `/obsidian-memory:doctor`
**Then** the skill prints `FAIL: <what's wrong> — <one-line remediation hint>` for that check
**And** the skill exits non-zero

Failure modes (each becomes its own Gherkin scenario via Scenario Outline):

| # | Failure mode | Example remediation hint |
|---|--------------|--------------------------|
| F1 | Config file missing | `run /obsidian-memory:setup <vault>` |
| F2 | `vaultPath` missing from config | `run /obsidian-memory:setup <vault>` |
| F3 | `vaultPath` is not a directory | `vault path <path> does not exist — run /obsidian-memory:setup <vault>` |
| F4 | `jq` not on PATH | `brew install jq` (or platform equivalent) |
| F5 | `claude` not on PATH | `install the Claude Code CLI; see https://docs.claude.com/claude-code` |
| F6 | `claude-memory/projects` symlink broken or missing | `run /obsidian-memory:setup <vault>` |
| F7 | `claude-memory/sessions/` missing | `run /obsidian-memory:setup <vault>` |
| F8 | `rag.enabled` is `false` in config | `run /obsidian-memory:toggle rag on` |
| F9 | `distill.enabled` is `false` in config | `run /obsidian-memory:toggle distill on` |

### AC3: Doctor is read-only — it never mutates state

**Given** any combination of healthy and broken checks
**When** the user runs `/obsidian-memory:doctor`
**Then** no file is created, modified, or deleted under `~/.claude/obsidian-memory/`, the vault, or `~/.claude/projects/`
**And** no symlink is created, removed, or retargeted

**Example**:
- Given: a scratch `$HOME` snapshot of every mtime under `$HOME/.claude/obsidian-memory/` and the scratch vault
- When: the doctor runs (in healthy, partially-broken, and fully-broken states)
- Then: the mtime snapshot matches exactly afterward — no inode or content diff

### AC4: Optional dependencies surface as informational, not failing

**Given** `ripgrep` (`rg`) is not on `PATH` but everything else is healthy
**When** the user runs `/obsidian-memory:doctor`
**Then** the skill prints an informational line: `INFO: ripgrep not on PATH — vault-rag.sh will use POSIX fallback`
**And** the skill exits 0 (not a failure)

### AC5: Doctor runs against a scratch `$HOME` in tests

**Given** the bats integration harness (issue #1)
**When** the doctor integration test runs
**Then** it reads and writes only under `$BATS_TEST_TMPDIR`
**And** it never touches the operator's real `~/.claude/` or real vault

### AC6: `--json` flag emits a machine-readable report

**Given** a healthy install
**When** the user runs `/obsidian-memory:doctor --json`
**Then** stdout is a single JSON object with one key per check (e.g., `config`, `vault_path`, `jq`, `claude`, `sessions_dir`, `projects_symlink`, `rag_enabled`, `distill_enabled`, `ripgrep`) and a top-level `ok` boolean
**And** each check value is one of `"ok"`, `"fail"`, or `"info"`
**And** exit code matches: 0 when `ok` is `true`, non-zero otherwise

---

### Generated Gherkin Preview

```gherkin
Feature: Doctor health-check reports install state
  As a Claude Code + Obsidian user who just installed obsidian-memory
  I want a one-command health check that tells me whether my install is working
  So that silent hook no-ops do not leave me believing memory is flowing when it isn't

  Scenario: Healthy install passes all checks
    Given a healthy obsidian-memory install in a scratch $HOME
    When I run /obsidian-memory:doctor
    Then every check reports OK
    And the exit code is 0

  Scenario Outline: Specific failure modes report a remediation hint
    Given <failure-mode> in a scratch $HOME
    When I run /obsidian-memory:doctor
    Then the output contains "FAIL: <reason>"
    And the output contains "<hint>"
    And the exit code is non-zero
    Examples:
      | failure-mode              | reason                          | hint                               |
      | missing config            | config file missing             | /obsidian-memory:setup             |
      | vaultPath missing         | vaultPath missing from config   | /obsidian-memory:setup             |
      | vaultPath not a directory | vault path does not exist       | /obsidian-memory:setup             |
      | jq not on PATH            | jq not on PATH                  | brew install jq                    |
      | claude not on PATH        | claude not on PATH              | Claude Code CLI                    |
      | projects symlink broken   | projects symlink                | /obsidian-memory:setup             |
      | sessions dir missing      | sessions directory              | /obsidian-memory:setup             |
      | rag disabled              | rag.enabled is false            | /obsidian-memory:toggle rag on     |
      | distill disabled          | distill.enabled is false        | /obsidian-memory:toggle distill on |

  Scenario: Doctor is read-only
    Given a snapshot of every mtime under the scratch $HOME
    When I run /obsidian-memory:doctor in any state
    Then no file or symlink under the scratch $HOME is created, modified, or removed

  Scenario: ripgrep missing is informational, not failing
    Given a healthy install but ripgrep is not on PATH
    When I run /obsidian-memory:doctor
    Then the output contains "INFO: ripgrep"
    And the exit code is 0

  Scenario: --json emits a machine-readable report
    Given a healthy install
    When I run /obsidian-memory:doctor --json
    Then stdout is a single JSON object
    And the object has an "ok" boolean equal to true
    And the exit code is 0
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Add `skills/doctor/SKILL.md` following the skill template in `steering/structure.md`. | Must | Issue body says `plugins/obsidian-memory/skills/doctor/SKILL.md` — this repo is a standalone plugin, so skills live at `skills/` (see `structure.md` → Project Layout). |
| FR2 | Implement the health checks listed in AC2 as pure read-only probes in a shell script under `scripts/`. | Must | The SKILL.md delegates to a script so the logic is bats-testable without invoking Claude. |
| FR3 | Exit code 0 if all checks pass, non-zero if any fail. Specific exit code does not need to encode which check failed — the summary output does that. | Must | |
| FR4 | Human-readable output: one line per check, `OK: <check-name>` or `FAIL: <reason> — <hint>` or `INFO: <note>`. Summary line at the end. | Must | |
| FR5 | Machine-readable output via `--json` flag: a JSON object with one key per check and an overall `ok` boolean. | Should | |
| FR6 | BDD scenarios for the happy path, each failure mode, read-only property, `--json` output, and optional-dep informational path. | Must | Lives at `specs/feature-doctor-health-check-skill/feature.gherkin`. |
| FR7 | Detect optional dependencies (`ripgrep`) and surface them as `INFO`, not `FAIL`. MCP registration is also informational. | Should | Optional deps do not gate a `0` exit. |
| FR8 | Color-coded output when stdout is a TTY; plain when piped. | Could | Use `[ -t 1 ]` to decide. ANSI escape codes are standard — no extra dependency. |
| FR9 | Output vocabulary is consistent with `/obsidian-memory:setup` ("vault path", "config", "symlink"). | Should | Reduces cognitive load across skills. |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Wall time < 500 ms in the common case; no network calls; no `claude -p` subprocess. |
| **Security** | Read-only against config, vault, and `~/.claude/projects/`. No write syscalls. No subprocess other than `jq`, `test`, `readlink`, `command -v`. |
| **Accessibility** | Plain-text output works in every terminal. Color is an enhancement, not a requirement. |
| **Reliability** | Doctor itself must not fail — a crash in doctor is worse than silent hook failure. Wrap unknown failure paths so the script always prints something and exits with a deterministic code. |
| **Platforms** | macOS default bash (3.2) and Linux bash 4+, per `steering/tech.md`. |

---

## UI/UX Requirements

Doctor has no GUI. Its "UI" is terminal output.

| Element | Requirement |
|---------|-------------|
| **Structure** | One line per check. Final summary line. Optional remediation hints on `FAIL` lines. |
| **Vocabulary** | Reuse terms from `setup` ("vault path", "config", "projects symlink", "sessions directory"). |
| **Color (TTY only)** | `OK` green, `FAIL` red, `INFO` yellow, summary in bold. Never colorize when `stdout` is piped. |
| **Empty state** | Not applicable — there is always at least one check to report. |
| **Error state** | If doctor itself cannot run (e.g., bash is missing), that is outside its scope. |

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `--json` flag | CLI flag | Presence only | No |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| stdout (human mode) | plain text | One line per check; final summary |
| stdout (JSON mode) | JSON object | One key per check + `ok` boolean |
| Exit code | int | 0 on success, non-zero on any `FAIL` |

---

## Dependencies

### Internal Dependencies

- [x] `scripts/_common.sh` — may be partially reused for config-loading helpers (read-only subset only)
- [x] `/obsidian-memory:setup` — doctor references setup in its remediation hints

### External Dependencies

- [x] `jq` — required at runtime (doctor checks for its presence before using it; if `jq` is missing, that becomes a FAIL with a hint rather than a crash)
- [ ] `ripgrep` — optional, informational

### Blocked By

- None. Issue #1 (bats-core harness) is already merged and available for the tests.

---

## Out of Scope

- **Auto-fixing any detected problem.** Doctor is strictly a reporter. Fixing belongs to `/obsidian-memory:setup` (already exists) or `/obsidian-memory:toggle` (issue #4).
- **Live RAG retrieval assertion** — checking that `vault-rag.sh` actually returns matches for a live prompt is covered by the integration tests from issue #1, not by doctor.
- **Remote version check** — comparing the installed version against the upstream nmg-plugins version. Tracked separately if ever needed.
- **Teardown verification** — doctor does not validate that `/obsidian-memory:teardown` has run cleanly; that belongs in its own skill.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Reported install-state accuracy | 100% for the 9 failure modes in AC2 | Integration test per failure mode asserts `FAIL` line and non-zero exit |
| Read-only invariant holds | 100% across a full scenario matrix | Pre/post mtime snapshot in a bats test |
| Doctor self-reliability | Zero crash reports (unhandled `set -u` or trap firings) | Covered by bats test against missing-everything scratch `$HOME` |

---

## Open Questions

- [ ] Should the `INFO:` lines for optional deps also include the MCP server registration status? (Recommended: yes; it matches user mental model.) — Resolved in design as *yes*, surfaced as `INFO`.
- [ ] Should `--json` output include the remediation hint text, or only `"fail"`? (Recommended: include `hint` field per check; cheap to add, useful for scripts.) — Resolved in design as *include `hint`*.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #2 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to PLAN phase:

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements (design.md will cover how)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases (read-only, optional deps, JSON output) are specified
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented
