# Requirements: Session distillation hook

**Issues**: #11
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user who ends many short sessions across many projects
**I want** each finished session automatically distilled into a dated Markdown note in my vault
**So that** my vault accumulates a browseable, editable memory of what every session did without me having to take notes manually

---

## Background

Retroactive baseline spec for the `SessionEnd → vault-distill.sh` hook as it ships in v0.1.0. This is the **write side** of the plugin — it is off the hot path (fires after the session exits) and spawns a nested `claude -p` subprocess to produce the distillation. The output is a plain Markdown file with YAML frontmatter, written under `<vault>/claude-memory/sessions/<project-slug>/` and linked from `Index.md`.

v0.1 hard-codes the distillation prompt ("Summary / Decisions / Patterns & Gotchas / Open Threads / Tags"). A configurable template is tracked separately in #7.

This spec describes current behavior only. It exists so downstream enhancement issues (#4 toggle, #6 per-project overrides, #7 template config) can amend or reference the baseline.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: A non-trivial session ends and is distilled (Happy Path)

**Given** an ongoing Claude Code session with a transcript at `$HOME/.claude/projects/<slug>/<sid>.jsonl` that is > 2,000 bytes
**And** setup has been run against `$VAULT`
**And** `distill.enabled=true` in config
**When** the session ends and Claude Code fires `SessionEnd` with payload `{ transcript_path, cwd, session_id, reason }`
**Then** a new file `<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` is created
**And** the file begins with YAML frontmatter containing `date`, `time`, `session_id`, `project`, `cwd`, `end_reason`, `source: claude-code`
**And** the body is the output of a nested `CLAUDECODE="" claude -p` call against the distillation prompt
**And** `<VAULT>/claude-memory/Index.md` has a new link line inserted immediately under the `## Sessions` heading
**And** the hook exits 0

### AC2: Trivial session (transcript < 2 KB) is skipped (Edge Case)

**Given** a transcript at `$TRANSCRIPT` whose size is < 2,000 bytes
**When** the `SessionEnd` hook fires with that transcript path
**Then** no file is written under `<VAULT>/claude-memory/sessions/`
**And** `Index.md` is unchanged
**And** the hook exits 0

### AC3: Distillation subprocess returns empty (Edge Case — fallback stub)

**Given** a non-trivial transcript
**And** the nested `claude -p` call produces no stdout (empty string)
**When** the hook writes the session note
**Then** the note is still created with valid YAML frontmatter
**And** the body contains the fallback stub `## Summary\n\nDistillation returned no content. See transcript: \`<TRANSCRIPT>\``
**And** `Index.md` is still updated with a link line
**And** the hook exits 0

### AC4: Index.md does not yet exist (Alternative Path)

**Given** `<VAULT>/claude-memory/Index.md` does not exist
**When** the first successful distillation runs
**Then** `Index.md` is created with the header `# Claude Memory Index`, the helper paragraph, a `## Sessions` heading, and the new link line
**And** the hook exits 0

### AC5: Index.md exists but lacks a `## Sessions` heading (Edge Case)

**Given** `<VAULT>/claude-memory/Index.md` exists but contains no `^## Sessions\s*$` line
**When** a distillation runs
**Then** a new `## Sessions` heading and link line are appended at the end of the file
**And** the existing file content is preserved verbatim
**And** the hook exits 0

### AC6: Distillation disabled via config flag (Alternative Path)

**Given** `~/.claude/obsidian-memory/config.json` has `distill.enabled=false`
**When** `SessionEnd` fires
**Then** no session note file is created
**And** `Index.md` is not modified
**And** the hook exits 0 without invoking `claude -p`

### AC7: Missing `claude` CLI (Error Handling — silent)

**Given** the `claude` binary is not on the hook subshell's `PATH`
**When** `SessionEnd` fires
**Then** the hook exits 0 with no file writes
**And** no stderr is surfaced to the user-visible session UI

### AC8: Missing `jq` dependency (Error Handling — silent)

**Given** `jq` is not on the hook subshell's `PATH`
**When** `SessionEnd` fires
**Then** the hook exits 0 with no file writes

### AC9: Missing config file (Error Handling — silent)

**Given** `~/.claude/obsidian-memory/config.json` does not exist
**When** `SessionEnd` fires
**Then** the hook exits 0 with no file writes

### AC10: Unreadable transcript path (Error Handling — silent)

**Given** the `SessionEnd` payload's `transcript_path` points at a file that does not exist or is not readable
**When** the hook fires
**Then** no session note is created
**And** the hook exits 0

### AC11: Project slug sanitization (Edge Case — Security)

**Given** the session's `cwd` is `/some/path/My Weird & Project/../etc`
**When** the hook derives the project slug from `basename "$CWD"`
**Then** the resulting slug matches `^[a-z0-9-]+$`
**And** no session file is written outside `<VAULT>/claude-memory/sessions/`

### AC12: Nested `claude -p` invocation clears `CLAUDECODE` (Security / Correctness)

**Given** the parent Claude Code process exported `CLAUDECODE=1`
**When** the hook invokes the nested `claude -p`
**Then** the child process receives `CLAUDECODE=""`
**And** the child does not refuse with "Cannot be launched inside another Claude Code session"

### AC13: Large transcript is capped at 200 KB of extracted conversation (Edge Case — Performance)

**Given** a transcript whose extracted user+assistant conversation would exceed 200 KB
**When** the hook prepares the distillation input
**Then** at most ~204,800 bytes of conversation are piped into `claude -p`
**And** the hook still completes successfully

### AC14: Transcript content-array vs content-string shapes (Edge Case)

**Given** a transcript where some messages have `.message.content` as an **array of parts** and others as a **plain string**
**When** the hook extracts conversation via `jq`
**Then** both shapes are flattened to newline-joined text
**And** `tool_use` parts are rendered as `[tool_use: <name>]`
**And** `tool_result` parts are rendered as stringified content

### Generated Gherkin Preview

```gherkin
Feature: Session distillation hook
  As a Claude Code + Obsidian user
  I want each finished session distilled into a vault note
  So that my vault accumulates browseable memory automatically

  Scenario: A non-trivial session ends and is distilled
    Given a transcript of at least 2 KB
    And distill.enabled is true
    When SessionEnd fires with {transcript_path, cwd, session_id, reason}
    Then a new dated note exists under sessions/<slug>/
    And Index.md has a new link line under "## Sessions"
    And the hook exits 0

  # ... all ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Read payload from stdin as JSON with `{ transcript_path, cwd, session_id, reason }` | Must | Hook protocol |
| FR2 | Exit 0 if `jq` or `claude` not on PATH, config missing, vault missing, `distill.enabled=false`, payload empty, transcript missing or unreadable | Must | Silent-fail rule |
| FR3 | Skip transcripts < 2,000 bytes | Must | "Trivial session" guard (AC2) |
| FR4 | Derive project slug from `basename "$CWD"`: lowercase, `tr -c 'a-z0-9-' '-'`, collapse runs, strip leading/trailing `-`, fall back to `unknown` | Must | Security + safety (AC11) |
| FR5 | Extract user+assistant messages via `jq`, handling array-of-parts and string content shapes; include `tool_use` and `tool_result` summaries; cap at 200 KB | Must | AC13, AC14 |
| FR6 | Invoke `CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null` with the hard-coded distillation prompt | Must | AC12 |
| FR7 | Write note to `<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` (UTC) with YAML frontmatter + body or fallback stub | Must | AC1, AC3 |
| FR8 | Insert link line `- [[sessions/<slug>/<ts>.md]] — <slug> (<date> <time> UTC)` into `Index.md` immediately under `## Sessions`; create Index.md if absent; append new `## Sessions` section if heading is missing | Must | AC1, AC4, AC5 |
| FR9 | Exit 0 on every terminating path; `set -u`, `trap 'exit 0' ERR` | Must | Per `tech.md` |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Wall time bounded only by the nested `claude -p` call (typically seconds to tens of seconds). No polling loops. Off hot path. |
| **Security** | Project slug sanitization prevents path escape (AC11). Transcript text is piped into `claude -p` via stdin/argv, never via shell composition. `CLAUDECODE=""` scoped only to the subprocess. |
| **Reliability** | Silent-fail on every documented failure mode; `trap 'exit 0' ERR` at top |
| **Privacy** | Transcript content flows to the user-authenticated `claude` CLI only; no network call by the hook itself |
| **Output size** | Distillation prompt asks for ≤ 500 words; resulting note typically < 4 KB |
| **Platforms** | macOS default bash 3.2 + Linux bash 4+ |

---

## UI/UX Requirements

Not applicable. The hook produces a Markdown file inside the user's Obsidian vault. The "UI" is the Obsidian editor displaying that file. Schema per `product.md`:

- Frontmatter: `date, time, session_id, project, cwd, end_reason, source`
- Body sections (LLM-authored): `## Summary`, `## Decisions`, `## Patterns & Gotchas`, `## Open Threads`, `## Tags` (Obsidian-style `#project/<slug>` plus 3–5 topical tags)

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| stdin `.transcript_path` | absolute path string | file exists + readable + ≥ 2,000 bytes | Yes (else exit 0) |
| stdin `.cwd` | absolute path string | falls back to `$(pwd)` if empty | No |
| stdin `.session_id` | string | falls back to `"unknown"` if empty | No |
| stdin `.reason` | string | falls back to `"unknown"` if empty | No |
| `~/.claude/obsidian-memory/config.json` | `{ vaultPath, distill.enabled }` | vault exists + `distill.enabled=true` | Yes (else exit 0) |

### Output Data

| Artefact | Shape |
|----------|-------|
| `<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` | YAML frontmatter + Markdown body (distilled or stub) |
| `<VAULT>/claude-memory/Index.md` | Newest-first link under `## Sessions`, format `- [[sessions/<slug>/<ts>.md]] — <slug> (<date> <time> UTC)` |
| exit code | `0` always |
| stderr | `trap`-logged failures only; never user-visible |

### Distillation prompt (fixed in v0.1.0)

```
You are distilling a Claude Code session transcript into a concise Obsidian note.

Output ONLY the note body in Markdown. No preamble. No outer code fences.

Include these sections (omit any that would be empty):

## Summary            (2–3 sentences on what the session accomplished)
## Decisions          (notable choices + reasoning)
## Patterns & Gotchas (file paths, commands, identifiers, non-obvious constraints)
## Open Threads       (unfinished work)
## Tags               (space-separated, starting with #project/<slug>, plus 3–5 topical tags)

Use Obsidian [[wiki-links]] for salient entities. Cap at ~500 words.

TRANSCRIPT: <up to ~200 KB of user+assistant messages>
```

---

## Dependencies

### Internal Dependencies

- [ ] `plugins/obsidian-memory/hooks/hooks.json` — declares `SessionEnd → scripts/vault-distill.sh`
- [ ] `~/.claude/obsidian-memory/config.json` — written by `/obsidian-memory:setup`

### External Dependencies

- [ ] `jq` — hard dep; hook no-ops if missing
- [ ] `claude` CLI — hard dep; hook no-ops if missing
- [ ] POSIX `awk`, `date`, `mkdir`, `mktemp`, `mv`, `basename`, `tr`, `sed`, `wc`, `head`

### Blocked By

- [ ] None

---

## Out of Scope

- Configurable distillation template (tracked in #7)
- Per-project overrides / opt-out (tracked in #6)
- Toggle skill for `distill.enabled` (tracked in #4)
- Re-distilling past sessions / back-fill over historical transcripts
- Manual mid-session checkpoint (that's `feature-manual-distill-skill` — #12)
- Editing an existing distilled note in place on re-run
- Cloud sync of distillations
- Non-Markdown output formats

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Distillation correctness | 0 hallucinated decisions or patterns across 20 sampled session notes | Human audit |
| Hook safety | 0 blocking failures (hook never keeps a session from ending cleanly) | Integration tests over the 10+ documented failure modes |
| Index.md integrity | `## Sessions` section remains valid Markdown with newest-first link ordering after 100 successive distillations | Integration test |
| Slug safety | Adversarial `cwd` values never produce a write outside `<VAULT>/claude-memory/sessions/` | Property-style tests over a fuzzer seed |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #11 | 2026-04-19 | Initial baseline spec — documents v0.1.0 shipped behavior |

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
