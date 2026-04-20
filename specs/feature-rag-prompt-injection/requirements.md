# Requirements: RAG prompt injection hook

**Issues**: #10
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user working across many projects
**I want** relevant prior notes from my vault surfaced automatically on every prompt
**So that** Claude answers with continuity from past sessions without me manually copy-pasting context

---

## Background

Retroactive baseline spec for the `UserPromptSubmit → vault-rag.sh` hook as it ships in v0.1.0. The hook is the **read side** of the plugin — it is on the hot path (runs on every prompt) and must be fast, safe, and silent on failure. It never writes to the vault.

v0.1 deliberately uses keyword matching rather than embeddings so that the whole retrieval pipeline is one shell script a human can read. Embeddings are a later one-script swap (#5) with no change to hook wiring.

This spec describes current behavior only. It exists so downstream enhancement issues (#4 toggle, #5 embedding swap, #6 per-project overrides) can amend or reference the baseline.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: Vault note contains a keyword from the prompt (Happy Path)

**Given** an Obsidian vault at `$VAULT` containing `my-note.md` with the text `"jq is used for config parsing"`
**And** setup has been run against `$VAULT`
**When** the user submits a prompt containing `"How do I use jq for config parsing?"`
**Then** the hook stdout contains a single `<vault-context source="obsidian" keywords="…">` opening tag
**And** the block contains the relative path `my-note.md` and the excerpt text "jq is used for config parsing"
**And** the block ends with `</vault-context>`
**And** the hook exits 0

### AC2: No matching notes (Happy Path — silent)

**Given** an Obsidian vault at `$VAULT` whose `.md` files contain no tokens overlapping the prompt
**And** setup has been run against `$VAULT`
**When** the user submits a prompt containing no words that match any vault file
**Then** the hook emits no `<vault-context>` block on stdout
**And** the hook exits 0

### AC3: `rg` not on PATH — POSIX fallback (Alternative Path)

**Given** `ripgrep` is not on the hook subshell's `PATH`
**And** a matching note exists in the vault
**When** the user submits a matching prompt
**Then** the hook still emits a `<vault-context>` block for that note
**And** it does so using `find` + `grep -c -i -E` rather than `rg`
**And** the hook exits 0

### AC4: RAG disabled via config flag (Alternative Path)

**Given** `~/.claude/obsidian-memory/config.json` has `rag.enabled=false`
**When** the user submits any prompt
**Then** the hook emits no output on stdout
**And** the hook exits 0 without reading the vault

### AC5: Exclusion list prevents feedback loop (Edge Case)

**Given** the vault's auto-memory symlink contains a note at `$VAULT/claude-memory/projects/some-project/2026-04-18.jsonl` with text "jq"
**And** no other `.md` file in the vault contains "jq"
**When** the user submits a prompt containing "jq"
**Then** the hook emits no `<vault-context>` block
**And** the hook exits 0

### AC6: Obsidian metadata directories excluded (Edge Case)

**Given** `$VAULT/.obsidian/workspace.json` and `$VAULT/.trash/deleted-note.md` each contain a prompt keyword
**And** no other file contains the keyword
**When** the user submits a matching prompt
**Then** the hook emits no `<vault-context>` block
**And** the hook exits 0

### AC7: Missing `jq` dependency (Error Handling — silent)

**Given** `jq` is not on the hook subshell's `PATH`
**When** the user submits any prompt
**Then** the hook exits 0 with no stdout
**And** the user's prompt is delivered unchanged

### AC8: Missing config file (Error Handling — silent)

**Given** `~/.claude/obsidian-memory/config.json` does not exist
**When** the user submits any prompt
**Then** the hook exits 0 with no stdout
**And** the user's prompt is delivered unchanged

### AC9: Stopwords are filtered (Edge Case)

**Given** an Obsidian vault where the only matches would be common stopwords
**And** the user's prompt is "the and for with that" (all stopwords)
**When** the hook processes the prompt
**Then** the hook emits no `<vault-context>` block
**And** the hook exits 0

### AC10: Keyword cap is enforced (Edge Case)

**Given** a prompt containing 20 distinct non-stopword tokens of ≥4 chars
**When** the hook tokenizes the prompt
**Then** at most 6 keywords are used in the search
**And** the alternation regex built is `(kw1|kw2|…|kw6)` with ≤6 alternatives

### AC11: Top-5 ranking and excerpt format (Happy Path — detail)

**Given** 10 vault notes each matching the prompt with different hit counts
**When** the hook runs
**Then** the `<vault-context>` block lists exactly 5 notes
**And** they are ordered by descending hit count
**And** each listed note has a `### <relative-path>  (hits: <N>)` header
**And** each note's excerpt is fenced in triple-backticks and capped at ~600 bytes

### AC12: Prompt-injection safety (Security)

**Given** a user prompt containing shell metacharacters like `$(whoami)`, `` ` ``, `;rm -rf /`, or single-quoted strings
**When** the hook processes the prompt
**Then** no subshell is spawned from prompt content
**And** the hook does not `eval` or string-concatenate prompt text into any shell command
**And** the hook exits 0 with at most a normal `<vault-context>` block containing literal keyword text

### Generated Gherkin Preview

```gherkin
Feature: RAG prompt injection hook
  As a Claude Code + Obsidian user
  I want relevant prior notes surfaced on every prompt
  So that Claude answers with continuity across sessions

  Scenario: Vault note contains a keyword from the prompt
    Given a vault with "my-note.md" containing "jq is used for config parsing"
    When the user submits a prompt containing "jq"
    Then the hook emits a <vault-context> block containing "my-note.md"

  # ... all ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Read JSON payload from stdin; extract `.prompt` via `jq` | Must | Hook protocol contract |
| FR2 | Read `~/.claude/obsidian-memory/config.json`; exit 0 if absent, unreadable, or `rag.enabled=false` | Must | Silent-fail rule |
| FR3 | Read `vaultPath` from config; exit 0 if missing or not a directory | Must | Guard against stale config |
| FR4 | Tokenize prompt: lowercase, split on non-alphanumerics, drop configured stopwords, dedupe, keep tokens ≥4 chars, cap at 6 | Must | Keyword extraction |
| FR5 | Build alternation regex `(kw1|kw2|…)` from keywords; exit 0 if no keywords survive filtering | Must | — |
| FR6 | Enumerate `*.md` files under `$VAULT` excluding `claude-memory/projects/**`, `.obsidian/**`, `.trash/**`; prefer `rg --files`, fall back to `find` | Must | No feedback loop |
| FR7 | Score each candidate by total hit count (`rg -c -i -o` or `grep -c -i -E`) | Must | — |
| FR8 | Select top 5 by descending hit count | Must | — |
| FR9 | Emit `<vault-context source="obsidian" keywords="…">` with per-file `### <rel-path>  (hits: <N>)` + fenced excerpt (first match, -B 2 -A 8, capped at 600 bytes) | Must | Format contract |
| FR10 | Exit 0 on every terminating path; log unexpected failures to stderr via `trap … ERR` | Must | Safety rule |
| FR11 | Never interpolate prompt content into a shell command; pass to `rg`/`grep` via `-e` flag with `--` separators | Must | Security rule |
| FR12 | Use `set -u` but **not** `set -e` at top level; internal helpers may return non-zero | Must | Per `tech.md` |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | `vault-rag.sh` wall time < 300 ms p95 on a 1,000-note vault |
| **Performance (payload)** | `<vault-context>` block ≤ 8 KB by default (5 notes × ~600 B excerpt + frame ≈ ≤ 4 KB in practice) |
| **Security** | Prompt content never enters `eval` or command string; only passed via `-e` flag or stdin; regex built from whitelisted characters |
| **Reliability** | Exit 0 on: missing `jq`, missing config, `rag.enabled=false`, empty prompt, empty keywords, empty vault, every fall-through path |
| **Platforms** | macOS default bash 3.2 + Linux bash 4+; POSIX `grep -r`, `find`, `awk`, `paste`, `tr`, `sort`, `head`, `mktemp` |
| **Accessibility** | N/A |

---

## UI/UX Requirements

Not applicable. The hook has no user-facing UI. Its "output surface" is the `<vault-context>` block that Claude Code prepends to the model context — the user never sees the raw block unless inspecting stderr or hook logs.

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| stdin JSON payload | `{ "prompt": string }` | `.prompt` non-empty after `jq -r` | Yes |
| `~/.claude/obsidian-memory/config.json` | `{ vaultPath, rag.enabled, distill.enabled }` | file readable; `vaultPath` is a real directory | Yes (or hook exits 0) |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| stdout | Markdown text (possibly empty) | Either `<vault-context>…</vault-context>` block or empty |
| exit code | int | Always 0 |
| stderr | text (optional) | Log output from `trap … ERR`; never parsed by Claude Code |

### Stopword list (current v0.1.0)

`the, and, for, with, that, this, from, have, your, what, when, where, which, will, would, could, should, there, their, them, than, then, into, over, been, being, does, doing, about, just, like, some, only, also, make, made, used, using, file, code, test, user, tool, want, need, help, here, http, https, bash, echo, true, false, null, none, please, cannot, issue, task, line, lines`

---

## Dependencies

### Internal Dependencies

- [ ] `plugins/obsidian-memory/hooks/hooks.json` — declares `UserPromptSubmit → scripts/vault-rag.sh`
- [ ] `~/.claude/obsidian-memory/config.json` — written by `/obsidian-memory:setup` (feature-vault-setup)

### External Dependencies

- [ ] `jq` — hard dependency; hook no-ops if missing
- [ ] `ripgrep` (`rg`) — optional; POSIX fallback otherwise

### Blocked By

- [ ] None — ships today

---

## Out of Scope

- Embedding-based / semantic retrieval (tracked in #5)
- Per-project override / exclusion config (tracked in #6)
- Toggle skill for `rag.enabled` (tracked in #4)
- Cross-project search surface (future `could-have`)
- Writing to the vault from the RAG hook (architecturally forbidden — see `product.md` anti-pattern)
- Configurable stopword list (future — hard-coded today)
- Configurable keyword cap (future — 6 today)
- Configurable excerpt size (future — ~600 B today)
- Configurable top-N (future — 5 today)

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| RAG relevance | Relevant notes surface on ≥60% of prompts where vault notes exist | Human-rated audit of 20 prompts against a seeded vault |
| Hook wall time (p95) | < 300 ms on a 1,000-note vault | Benchmark in `tests/integration/` with a seeded fixture vault |
| Hook safety | Exit 0 on 100% of failure modes (missing dep, missing config, disabled flag, empty prompt) | Integration tests covering each path |
| No feedback-loop contamination | 0 `<vault-context>` blocks contain text from `claude-memory/projects/**` across an audit of 20 runs | Manual audit against a vault with seeded distillations |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #10 | 2026-04-19 | Initial baseline spec — documents v0.1.0 shipped behavior |

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
