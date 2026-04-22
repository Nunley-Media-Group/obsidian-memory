# Requirements: Toggle Skill for rag/distill Enable Flags

**Issues**: #4
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user troubleshooting a hook or temporarily stepping out of RAG
**I want** a one-command way to flip `rag.enabled` / `distill.enabled`
**So that** I do not have to hand-edit `~/.claude/obsidian-memory/config.json` every time I need to disable a hook.

---

## Background

`steering/product.md` names this explicitly as a v1 "Should Have": *"Disable-flag UX: clear docs + a skill that toggles `rag.enabled` / `distill.enabled` without editing JSON by hand."* Today, disabling either hook means opening the config in an editor, flipping the flag, saving — a friction point encountered exactly when the user is already debugging.

Typical triggers for toggling:

- The RAG hook is injecting context the user does not want for a specific working session.
- Distillation is misbehaving and the user needs to stop writing to the vault while investigating.
- The user wants to confirm that a problem originates from obsidian-memory by temporarily disabling it.

The existing `/obsidian-memory:doctor` skill already routes users here: its remediation hints include `run /obsidian-memory:toggle rag on` and `run /obsidian-memory:toggle distill on` when a feature is reported disabled (see `skills/doctor/SKILL.md`). Shipping toggle closes that loop.

**Path correction vs. the source issue.** The source issue's FR1 names the path `plugins/obsidian-memory/skills/toggle/SKILL.md`. Per `steering/structure.md` ("the repo root IS the plugin root"), the correct location is `skills/toggle/SKILL.md` — the repo is a standalone plugin, not a multi-plugin monorepo. Existing skills (`skills/setup/`, `skills/doctor/`, `skills/teardown/`, `skills/distill-session/`) confirm the layout. The FR below is written against the correct path.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: Explicit enable flips the flag and reports the prior and new state

**Given** a healthy config at `~/.claude/obsidian-memory/config.json` with `rag.enabled = true`
**When** the user runs `/obsidian-memory:toggle rag off`
**Then** `rag.enabled` becomes `false` in the config
**And** the skill prints the previous value (`true`) and the new value (`false`) for `rag.enabled`
**And** the skill exits 0.

**Example**:
- Given: config `{"vaultPath":"…","rag":{"enabled":true},"distill":{"enabled":true}}`
- When: `vault-toggle.sh rag off`
- Then: stdout contains `rag.enabled: true -> false`; config on disk now shows `"rag": {"enabled": false}`; exit code 0.

### AC2: Toggle without an explicit state flips the current value

**Given** a healthy config with `distill.enabled = false`
**When** the user runs `/obsidian-memory:toggle distill` (no state argument)
**Then** `distill.enabled` becomes `true` in the config
**And** the skill reports the flip (`distill.enabled: false -> true`)
**And** the skill exits 0.

### AC3: Status read-out prints both flags and does not mutate the config

**Given** any valid config
**When** the user runs `/obsidian-memory:toggle status` — or `/obsidian-memory:toggle` with no arguments
**Then** the skill prints the current value of both `rag.enabled` and `distill.enabled`
**And** the config file's content, mtime, and inode are unchanged
**And** the skill exits 0.

**Example**:
- Given: config with `rag.enabled=true`, `distill.enabled=false`
- When: `vault-toggle.sh status`
- Then: stdout contains `rag.enabled: true` and `distill.enabled: false`; config bytes on disk are byte-for-byte identical to the pre-run state.

### AC4: Unknown feature name errors cleanly

**Given** any valid config
**When** the user runs `/obsidian-memory:toggle foobar on`
**Then** the skill prints an error on stderr naming the allowed features (`rag`, `distill`)
**And** the skill exits non-zero
**And** the config file is unchanged (content, mtime, inode).

### AC5: Missing config is a clean error, not a crash

**Given** `~/.claude/obsidian-memory/config.json` does not exist
**When** the user runs `/obsidian-memory:toggle rag on`
**Then** the skill prints on stderr: `config not found — run /obsidian-memory:setup <vault> first`
**And** the skill exits non-zero
**And** no file is created under `~/.claude/obsidian-memory/`.

### AC6: Writes are atomic — interrupted toggle never leaves a half-written config

**Given** any valid toggle that will mutate the config
**When** the skill rewrites the config
**Then** it writes the new JSON to a temp file in the same directory as the config
**And** it uses `mv` (atomic on the same filesystem) to replace the original
**And** at no observable point is the config file truncated, empty, or containing a partial JSON document — even if the skill is killed mid-write (SIGKILL) the original config remains intact on disk.

**Example**:
- Given: config containing `"rag":{"enabled":true}` plus an unrelated user-added key `"customFoo":42`
- When: `vault-toggle.sh rag off` runs to completion
- Then: the post-run config still contains `"customFoo":42` byte-for-byte; the only change is the boolean; no `.tmp` artifacts remain in `~/.claude/obsidian-memory/`.

### AC7: "Already that state" is a success, not an error

**Given** `rag.enabled = true`
**When** the user runs `/obsidian-memory:toggle rag on`
**Then** the skill prints `rag.enabled was already true` (informational)
**And** the skill exits 0
**And** the config file's content, mtime, and inode are unchanged (no rewrite for a no-op).

### AC8: On/off aliases are accepted

**Given** a healthy config with `rag.enabled = true`
**When** the user runs `/obsidian-memory:toggle rag <alias>` where `<alias>` is any of `off`, `false`, `0`, `no`
**Then** `rag.enabled` becomes `false` (or is reported already-false per AC7 if it was already)
**And** the same aliasing applies to `on`, `true`, `1`, `yes` → `true`.

**Scenario Outline data**:

| alias | expected value |
|-------|----------------|
| on    | true  |
| true  | true  |
| 1     | true  |
| yes   | true  |
| off   | false |
| false | false |
| 0     | false |
| no    | false |

### Generated Gherkin Preview

```gherkin
Feature: Toggle Skill for rag/distill Enable Flags
  As a Claude Code + Obsidian user troubleshooting a hook or temporarily stepping out of RAG
  I want a one-command way to flip rag.enabled / distill.enabled
  So that I do not have to hand-edit ~/.claude/obsidian-memory/config.json every time

  # one scenario per AC above (AC8 becomes a Scenario Outline)
```

---

## Functional Requirements

| ID  | Requirement | Priority | Notes |
|-----|-------------|----------|-------|
| FR1 | Ship the skill at `skills/toggle/SKILL.md` following the thin-relayer pattern used by `skills/doctor/SKILL.md` and `skills/teardown/SKILL.md`. | Must | Path is corrected from the issue's original `plugins/obsidian-memory/…`. See Background → *Path correction*. |
| FR2 | Implement the logic in `scripts/vault-toggle.sh`; the skill shells out and relays stdout + exit code verbatim. | Must | Matches the doctor / teardown pattern — keeps behavior unit-testable with `bats` against a scratch `$HOME`. |
| FR3 | Accept invocations: `toggle <feature> <state>`, `toggle <feature>` (flip), `toggle status`, `toggle` (status shorthand). | Must | `<state>` honors the aliases from FR8. |
| FR4 | Feature whitelist is exactly `rag` and `distill`. Any other feature argument prints a usage line naming the allowed features to stderr and exits non-zero. | Must | Hard-coded list. No dynamic discovery. |
| FR5 | Mutating writes are atomic: `jq` renders new JSON to a temp file in the same directory as the config, then `mv`-into-place. On success the temp file is gone; on any internal failure the original config is untouched. | Must | Required by AC6. |
| FR6 | Preserve every unrelated key in the config (e.g., `vaultPath`, any user-added extensions). Use `jq --indent 2` so formatting matches what `/obsidian-memory:setup` writes. | Must | Regression guard: setup's tests will break if we drift from 2-space indent. |
| FR7 | BDD scenarios cover: explicit on, explicit off, flip (no state arg), status, status-shorthand (no args), unknown feature, missing config, atomic-write survival, already-in-state no-op, and the state-alias Scenario Outline. | Must | Listed in tasks under the Testing phase. |
| FR8 | Exit codes: 0 on success (including the already-in-state case), non-zero on any error (unknown feature, missing config, unreadable config, failed write). | Must | Aligns with exit-code semantics already used by doctor (0 vs 1) and teardown (0 / 1 / 2). |
| FR9 | State aliases: accept `on`, `true`, `1`, `yes` as `true`; `off`, `false`, `0`, `no` as `false`. Case-insensitive. Anything else errors with a usage line. | Should | Upgraded from "Could" in the source issue — trivial to implement, non-trivial UX cost to omit. |
| FR10 | Doctor skill cross-reference: no code change needed, but this spec inherits the existing `doctor` remediation hints (`run /obsidian-memory:toggle rag on` / `… distill on`). Verify on completion that those hints still resolve. | Must | Prevents circular doc rot. |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Toggle must complete in well under 100 ms on a warm filesystem. It is user-facing and interactive; no polling or sleeping. |
| **Security** | No prompt text or untrusted input is ever interpolated into a shell command (per `steering/tech.md` → Security). All argv comes from the user's typed command line; no network calls. |
| **Reliability** | Atomic write (FR5) guarantees the config is never left in a partial or corrupt state. A user killing the skill mid-run must not require `/obsidian-memory:setup` to recover. |
| **Platforms** | macOS default bash 3.2 and Linux bash 4+ per `steering/tech.md`. BSD `mv` and `jq ≥ 1.6` are the only required tools (inherited from existing scripts). |

---

## UI/UX Requirements

The skill has no UI other than stdout/stderr. Output conventions:

| Element | Requirement |
|---------|-------------|
| **Mutation output** | `<feature>.enabled: <prev> -> <new>` on stdout, e.g., `rag.enabled: true -> false`. |
| **No-op output** | `<feature>.enabled was already <value>` on stdout. |
| **Status output** | Two lines, one per feature: `rag.enabled: true` and `distill.enabled: false`. |
| **Error output** | Everything to stderr. First line starts with `ERROR:` so machine-parsers can filter. |
| **Color** | None. Other scripts (`vault-doctor.sh`) use ANSI only behind `[ -t 1 ]`; this skill's output is simple enough to ship uncolored. |

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `<feature>` | string argv | exactly `rag` or `distill`; `status` is also accepted as a verb | No (absent = `status`) |
| `<state>` | string argv | one of `on`, `off`, `true`, `false`, `1`, `0`, `yes`, `no` (case-insensitive) | No (absent = flip current value) |

### Config file touched

| Path | Keys read | Keys written |
|------|-----------|--------------|
| `~/.claude/obsidian-memory/config.json` | `.rag.enabled`, `.distill.enabled` (unset → treated as `true` per `_common.sh` semantics, but only for reporting; writes always produce an explicit boolean) | `.rag.enabled` or `.distill.enabled` (one at a time); every other key is preserved byte-for-byte |

---

## Dependencies

### Internal Dependencies

- [x] `/obsidian-memory:setup` must have already written `~/.claude/obsidian-memory/config.json`. Toggle does not create the config from scratch.
- [x] `jq` ≥ 1.6 on `PATH` (required for read and atomic write).

### External Dependencies

None. Toggle is local-only — no network, no `claude -p` subprocess.

### Blocked By

None.

---

## Out of Scope

- Per-project overrides (tracked by issue #6).
- A global master-disable across all hooks at once ("kill switch"). If we want one, it gets its own issue.
- Any UI beyond stdout/stderr text.
- A config-migration / rename path — this skill only flips booleans, never renames keys.
- Toggling keys other than `rag.enabled` and `distill.enabled`. Future features that want a toggle extend the FR4 whitelist in a separate issue.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Time to disable a hook (user-observed) | ≤ 5 s from "I need to disable RAG" to flag flipped | Self-measured via session notes; no instrumentation. |
| Config corruption events | 0 | Integration test asserts atomic-write invariant (AC6). |
| Doctor remediation-hint accuracy | 100% of toggle invocations from doctor's hints succeed | Manual spot-check once shipped; covered implicitly by end-to-end BDD scenario. |

---

## Open Questions

None. The source issue's "Notes" resolved the "already in state" semantics (AC7), and FR9 upgrades the aliasing question.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #4 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to PLAN phase:

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements (except FR-level file paths, which are deliberate)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases (no-op, aliases, missing config, atomic write) are specified
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented (or resolved)
