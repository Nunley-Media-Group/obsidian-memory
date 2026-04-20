# Requirements: Manual distill-session skill

**Issues**: #12
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user mid-session
**I want** a manual command that runs the same distillation the `SessionEnd` hook would run
**So that** I can checkpoint a long session or a natural break without waiting to exit, and preserve intermediate reasoning in my vault

---

## Background

Retroactive baseline spec for the `/obsidian-memory:distill-session` skill as it ships in v0.1.0. The skill is an **on-demand sibling** of the `SessionEnd → vault-distill.sh` hook (see `feature-session-distillation-hook` / #11). It does not reimplement distillation — it locates the newest JSONL transcript under `~/.claude/projects/`, synthesizes a `SessionEnd`-shaped payload, and pipes it into the same `vault-distill.sh` script so both paths produce identical artefacts.

Typical user story: after `/write-spec` completes and before `/write-code` starts, the user wants the intermediate reasoning preserved so future sessions' RAG can retrieve it without waiting for the current session to end.

This spec describes current behavior only. It exists so downstream enhancement issues (#4 toggle, #7 configurable template) can amend or reference the baseline.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: Manual distillation during an active session (Happy Path)

**Given** an active Claude Code session has been producing a transcript at `$HOME/.claude/projects/my-proj/<sid>.jsonl` that is > 2 KB
**And** setup has been run against `$VAULT`
**And** `distill.enabled=true`
**When** the user invokes `/obsidian-memory:distill-session`
**Then** the skill identifies the newest `*.jsonl` under `~/.claude/projects/` as `$TRANSCRIPT`
**And** the skill pipes a payload `{ transcript_path, cwd, session_id, reason: "manual" }` into `plugins/obsidian-memory/scripts/vault-distill.sh`
**And** a new note is created under `$VAULT/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md`
**And** the note's frontmatter `end_reason` field is `"manual"`
**And** the skill prints the path to the latest note and (optionally) its first ~40 lines

### AC2: No transcripts exist yet (Error Handling)

**Given** `~/.claude/projects/` contains no `*.jsonl` files
**When** the user invokes `/obsidian-memory:distill-session`
**Then** the skill reports "no Claude Code transcripts found"
**And** stops without calling `vault-distill.sh`
**And** no file is written under `$VAULT/claude-memory/sessions/`

### AC3: Missing `jq` or `claude` CLI (Error Handling)

**Given** `jq` or `claude` is not on PATH
**When** the user invokes `/obsidian-memory:distill-session`
**Then** the skill reports the missing dependency and stops
**And** does not pipe into `vault-distill.sh`

### AC4: Idempotency — re-running produces a new timestamped note (Alternative Path)

**Given** a manual distillation has just produced `<slug>/2026-04-19-143022.md`
**When** the user invokes `/obsidian-memory:distill-session` again ~1 second later
**Then** a new file `<slug>/2026-04-19-<new-ts>.md` is created with a strictly newer timestamp
**And** the previous note is unchanged

### AC5: Project slug derived from current working directory (Alternative Path)

**Given** the user's current working directory is `$CWD = /path/to/my-weird-project`
**When** the user invokes `/obsidian-memory:distill-session`
**Then** the skill passes `cwd=$CWD` into the hook payload
**And** the note is written under `$VAULT/claude-memory/sessions/my-weird-project/…`

### AC6: Reuses the underlying hook's safety semantics (Alternative Path)

**Given** any condition that would cause `vault-distill.sh` to silently exit 0 (disabled flag, config missing, trivial transcript)
**When** the user invokes `/obsidian-memory:distill-session`
**Then** the skill reports what was produced (or that the fallback stub was written, or that the hook no-op'd)
**And** the skill itself does not error out

### AC7: Fallback stub detection and reporting (Edge Case)

**Given** the underlying `claude -p` subprocess returned empty content and the hook wrote a fallback stub
**When** the skill locates the resulting note
**Then** the skill reports that the note is a fallback stub (based on the "Distillation returned no content" marker)
**And** still prints the note path

### Generated Gherkin Preview

```gherkin
Feature: Manual distill-session skill
  As a Claude Code + Obsidian user mid-session
  I want a manual command that runs the same distillation the SessionEnd hook runs
  So that I can checkpoint without waiting for the session to exit

  Scenario: Manual distillation during an active session
    Given an active session with a 5 KB transcript
    When the user runs /obsidian-memory:distill-session
    Then a new dated note is written with end_reason "manual"

  # ... all ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Check prerequisites: `jq` and `claude` on PATH; config file exists | Must | Report missing and stop; do not invoke the hook (AC3) |
| FR2 | Locate newest `*.jsonl` under `~/.claude/projects/` via `find -print0 \| xargs -0 ls -1t \| head -n 1` | Must | `$TRANSCRIPT` |
| FR3 | If no transcript found, report "no Claude Code transcripts found" and stop | Must | AC2 |
| FR4 | Derive `SESSION_ID = basename $TRANSCRIPT .jsonl`; `CWD = pwd`; `REASON = "manual"` | Must | AC5 |
| FR5 | Synthesize JSON payload via `jq -n` with `transcript_path`, `cwd`, `session_id`, `reason` keys | Must | Hook contract |
| FR6 | Pipe payload into `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-distill.sh` | Must | Reuses the hook script exactly |
| FR7 | Read `vaultPath` from config; compute project slug the same way the hook does; locate newest `<slug>/<ts>.md` | Must | For reporting |
| FR8 | Report: transcript used, project slug, output note path, whether it is a fallback stub | Must | AC1, AC7 |
| FR9 | Never overwrite an existing distilled note; re-running produces a new timestamped file | Must | AC4 — hook-level guarantee |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Skill wall time is dominated by the underlying hook (bounded by `claude -p`); skill overhead < 100 ms |
| **Security** | Reuses the hook's slug sanitization; skill itself does not accept file paths from prompt content |
| **Reliability** | Skill failure modes are additive to the hook's — skill aborts cleanly on missing deps (AC3) or no transcripts (AC2); hook handles the remaining failure modes silently |
| **Platforms** | macOS default bash 3.2 + Linux bash 4+ |
| **Idempotency** | Never overwrites; every invocation produces a new timestamped note |

---

## UI/UX Requirements

| Element | Requirement |
|---------|-------------|
| **Invocation** | `/obsidian-memory:distill-session` (no arguments) |
| **Success output** | Transcript path + project slug + note path + fallback-stub flag |
| **Empty-vault output** | "no Claude Code transcripts found" |
| **Missing-deps output** | "jq missing" and/or "claude missing"; stop |

The skill's "UI" is the terminal output rendered by Claude Code's skill runtime. No interactive prompts (unlike `/obsidian-memory:setup`).

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `$CWD` | absolute path | derived from `pwd` | No (auto-derived) |
| Newest `*.jsonl` under `~/.claude/projects/` | filesystem scan | non-empty | Yes (else skill reports and stops) |

### Output Data

| Artefact | Owner |
|----------|-------|
| `$VAULT/claude-memory/sessions/<slug>/<new-ts>.md` | Written by `vault-distill.sh` (reused) |
| `$VAULT/claude-memory/Index.md` link insert | Written by `vault-distill.sh` (reused) |
| Skill stdout | Transcript path, slug, note path, fallback-stub marker |

The skill writes no files directly. All artefact creation is delegated to `vault-distill.sh`.

---

## Dependencies

### Internal Dependencies

- [ ] `plugins/obsidian-memory/scripts/vault-distill.sh` — the workhorse (`feature-session-distillation-hook` / #11)
- [ ] `~/.claude/obsidian-memory/config.json` — written by `/obsidian-memory:setup` (`feature-vault-setup` / #9)

### External Dependencies

- [ ] `jq` — hard dep; skill aborts if missing
- [ ] `claude` CLI — hard dep; skill aborts if missing
- [ ] POSIX `find`, `xargs`, `ls`, `head`, `basename`, `tr`, `sed`, `pwd`

### Blocked By

- [ ] None

---

## Out of Scope

- Any distillation logic itself (owned by `feature-session-distillation-hook` / #11)
- Configurable distillation template (tracked in #7)
- Choosing a non-newest transcript (always the newest)
- Distilling multiple past sessions in a single invocation
- Backfilling historical transcripts
- Editing an existing distilled note in place
- Prompting for confirmation (no-arg invocation is non-interactive by design)

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Skill output parity with the hook | 100% of artefacts produced by the skill are byte-identical in format to artefacts produced by the hook for the same transcript | Integration test: run skill vs. hook against the same transcript fixture; diff frontmatter keys + Index.md link format |
| Re-run uniqueness | Running the skill twice within 1 second produces two distinct timestamped files | AC4 integration test |
| Clean-failure rate | 100% of documented failure modes (no transcripts, missing deps) produce a user-visible message, not a stack trace | Skill-runtime transcripts inspection |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #12 | 2026-04-19 | Initial baseline spec — documents v0.1.0 shipped behavior |

---

## Validation Checklist

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases and error states are specified
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented (or resolved)
