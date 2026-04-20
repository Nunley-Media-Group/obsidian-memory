# Requirements: Vault setup skill

**Issues**: #9
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian power user
**I want** a single one-time command that points obsidian-memory at my vault
**So that** every future Claude Code session on every project benefits from vault-backed memory with no per-project wiring

---

## Background

Retroactive baseline spec for the `/obsidian-memory:setup` skill as it ships in v0.1.0. The skill is the single entry point between installing the plugin and having working hooks — without it, `vault-rag.sh` and `vault-distill.sh` no-op forever because there is no config file. Setup must be idempotent so the user can re-run it when switching vaults, changing machines, or recovering from a broken symlink.

This spec describes current behavior only. It exists so downstream enhancement issues (#2 doctor skill, #3 teardown, #4 toggle, #6 per-project overrides) can amend or reference the baseline.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: First-run setup against a real vault (Happy Path)

**Given** an empty Obsidian vault at `$VAULT` exists on disk
**And** `~/.claude/obsidian-memory/config.json` does not exist
**When** the user runs `/obsidian-memory:setup $VAULT`
**Then** `~/.claude/obsidian-memory/config.json` is written with `vaultPath=$VAULT`, `rag.enabled=true`, `distill.enabled=true`
**And** `$VAULT/claude-memory/sessions/` exists as a directory
**And** `$VAULT/claude-memory/projects` is a symlink pointing at `~/.claude/projects`
**And** `$VAULT/claude-memory/Index.md` exists and contains the "Claude Memory Index" header and a `## Sessions` heading

### AC2: Re-run setup is a no-op (Idempotency)

**Given** setup has already completed successfully against `$VAULT`
**And** `Index.md` and `config.json` are present with user-level edits preserved
**When** the user runs `/obsidian-memory:setup $VAULT` a second time
**Then** `config.json` retains the same `vaultPath` and any extra user keys are preserved
**And** `Index.md` is not rewritten or duplicated
**And** the `projects` symlink still points at `~/.claude/projects`

### AC3: Vault path does not exist (Error Handling)

**Given** the path `$VAULT` does not exist on disk
**When** the user runs `/obsidian-memory:setup $VAULT`
**Then** setup stops and tells the user the vault does not exist
**And** no file under `~/.claude/obsidian-memory/` is created
**And** no directory under the (non-existent) `$VAULT` is created

### AC4: Existing non-symlink `projects` entry (Error Handling)

**Given** `$VAULT/claude-memory/projects` already exists as a regular file or directory (not a symlink)
**When** the user runs `/obsidian-memory:setup $VAULT`
**Then** setup refuses to delete or replace it
**And** prints a message telling the user to move or remove `$VAULT/claude-memory/projects` manually
**And** continues with the remaining setup steps (config, sessions dir, Index.md)

### AC5: Stale symlink pointing elsewhere (Alternative Path)

**Given** `$VAULT/claude-memory/projects` is a symlink pointing at a stale path (not `~/.claude/projects`)
**When** the user runs `/obsidian-memory:setup $VAULT`
**Then** the symlink is atomically recreated to point at `~/.claude/projects`
**And** no user data is deleted

### AC6: Optional MCP registration — user opts in (Alternative Path)

**Given** the user has the Obsidian Claude Code MCP plugin installed
**When** setup prompts for MCP registration and the user answers "Yes"
**Then** `claude mcp add -s user obsidian --transport websocket ws://localhost:22360` is invoked
**And** a non-zero exit from `claude mcp add` is treated as non-fatal and reported

### AC7: Optional MCP registration — user skips (Alternative Path)

**Given** the user is prompted for MCP registration
**When** the user answers "No" or "Skip"
**Then** no `claude mcp` command is invoked
**And** setup continues to the final report

### AC8: Missing deps at setup time (Edge Case)

**Given** `jq` and/or `claude` are not on `PATH` when setup runs
**When** the user runs `/obsidian-memory:setup $VAULT`
**Then** setup completes the filesystem steps (config, dirs, symlink, Index.md)
**And** the final report lists the missing dependencies
**And** setup does not fail

### Generated Gherkin Preview

```gherkin
Feature: Vault setup skill
  As a Claude Code + Obsidian power user
  I want a single one-time command that points obsidian-memory at my vault
  So that every future Claude Code session benefits from vault-backed memory

  Scenario: First-run setup against a real vault
    Given an empty Obsidian vault at "$VAULT"
    And no config file exists
    When the user runs "/obsidian-memory:setup $VAULT"
    Then the config file is written with vaultPath, rag.enabled=true, distill.enabled=true
    And "$VAULT/claude-memory/sessions/" exists
    And "$VAULT/claude-memory/projects" is a symlink to "~/.claude/projects"
    And "$VAULT/claude-memory/Index.md" exists with the memory-index header

  Scenario: Re-run setup is idempotent
    Given setup has already completed against "$VAULT"
    When the user runs "/obsidian-memory:setup $VAULT" again
    Then existing config keys are preserved
    And Index.md is not duplicated
    And the projects symlink is unchanged

  # ... all ACs become scenarios
```

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Resolve vault path from `$1` or interactive prompt; expand leading `~`; verify directory exists; abort if missing | Must | Never create the vault |
| FR2 | Write `~/.claude/obsidian-memory/config.json` with `vaultPath`, `rag.enabled=true`, `distill.enabled=true`; preserve extra keys on re-run | Must | Only `vaultPath` is overwritten on re-run |
| FR3 | Create `<vault>/claude-memory/sessions/` if absent | Must | `mkdir -p` semantics |
| FR4 | Create or repoint `<vault>/claude-memory/projects` symlink to `~/.claude/projects`; refuse if a non-symlink exists there | Must | `ln -sfn` for repoint; never delete non-symlink |
| FR5 | Initialize `<vault>/claude-memory/Index.md` only if absent | Must | Leave existing Index.md untouched |
| FR6 | Prompt for optional MCP registration; run `claude mcp add -s user obsidian --transport websocket ws://localhost:22360` on "Yes"; treat non-zero as non-fatal | Should | Opt-in only |
| FR7 | Dependency check for `jq`, `rg`, `claude` via `command -v`; report missing | Should | `jq`+`claude` required; `rg` optional |
| FR8 | Smoke-test `vault-rag.sh` with a synthetic payload; print output | Should | Empty result is acceptable |
| FR9 | Print final report: config path, vault path, symlink target, Index.md path, MCP status, missing deps | Must | Operator-inspectable summary |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Setup wall-clock time < 5 s excluding the interactive MCP prompt |
| **Security** | Writes only under `~/.claude/obsidian-memory/` and `<vault>/claude-memory/`; never accepts paths from prompt content; never runs arbitrary shell from user input |
| **Reliability** | Every step idempotent; safe to re-run 5× per the success metric in `product.md` |
| **Platforms** | macOS default bash 3.2, Linux bash 4+; POSIX-compatible `test -L` / `readlink` checks |
| **Accessibility** | N/A — CLI skill with no UI |

---

## UI/UX Requirements

Not applicable. The skill is a terminal-only Claude Code invocation; its "UI" is the final report printed to stdout and the optional `AskUserQuestion` MCP prompt.

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `$1` (vault-path) | absolute path (string) | directory exists; leading `~` expanded | Yes (or via AskUserQuestion) |
| MCP opt-in answer | "Yes" \| "No" \| "Skip" | enum from `AskUserQuestion` | Yes |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| `~/.claude/obsidian-memory/config.json` | JSON | `{ vaultPath, rag: { enabled }, distill: { enabled } }` + any preserved user keys |
| `<vault>/claude-memory/sessions/` | directory | Parent for distilled session notes |
| `<vault>/claude-memory/projects` | symlink | → `~/.claude/projects` |
| `<vault>/claude-memory/Index.md` | Markdown | `# Claude Memory Index` + `## Sessions` |
| final report | stdout | summary of actions taken and deps present/missing |

---

## Dependencies

### Internal Dependencies

- [ ] `scripts/vault-rag.sh` — invoked for the smoke test in step 6

### External Dependencies

- [ ] `jq` ≥ 1.6 — required for the plugin's hooks at runtime; warned if missing
- [ ] `claude` CLI — required for distillation hook; warned if missing
- [ ] `ripgrep` (`rg`) — optional; falls back to POSIX `grep -r` / `find`
- [ ] [obsidian-claude-code-mcp](https://github.com/iansinnott/obsidian-claude-code-mcp) — optional; registered on user opt-in

### Blocked By

- [ ] None

---

## Out of Scope

- Teardown / uninstall path (tracked in #3)
- Doctor/health-check (tracked in #2)
- Toggle skill for `rag.enabled` / `distill.enabled` (tracked in #4)
- Per-project overrides (tracked in #6)
- Configurable distillation template (tracked in #7)
- Embedding-based retrieval swap (tracked in #5)
- Creating the Obsidian vault itself if missing (user-owned; setup aborts)
- MCP *plugin* installation inside Obsidian (out-of-band step)

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Setup idempotency | 5 consecutive re-runs produce zero drift in `config.json`, symlinks, or `Index.md` | Integration test re-running setup 5× and diffing artefact state |
| Setup success rate on clean install | 100% when vault exists and `jq`/`claude` are on PATH | Smoke test in CI against a scratch vault |
| First-run-to-working-hooks latency | < 5 s of wall-clock time (excluding the MCP prompt) | `time` around the skill invocation in integration tests |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #9 | 2026-04-19 | Initial baseline spec — documents v0.1.0 shipped behavior |

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
