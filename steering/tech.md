# obsidian-memory Technical Steering

This document defines the technology stack, constraints, and integration standards.
All technical decisions should align with these guidelines.

---

## Architecture Overview

```
Claude Code session
        │
        ├── UserPromptSubmit ──▶ hooks/vault-rag.sh ──▶ keyword-grep over <vault>/**/*.md
        │                                                (ripgrep; fallback: grep -r / find)
        │                                                ──▶ emits <vault-context>…</vault-context>
        │                                                    prepended to the prompt
        │
        └── SessionEnd ────────▶ hooks/vault-distill.sh ─▶ reads ~/.claude/projects/**/*.jsonl (newest)
                                                          ──▶ spawns  CLAUDECODE="" claude -p
                                                              (nested, non-interactive)
                                                          ──▶ writes <vault>/claude-memory/sessions/
                                                                      <project-slug>/YYYY-MM-DD-HHMMSS.md
                                                          ──▶ appends link to <vault>/claude-memory/Index.md

Configuration: ~/.claude/obsidian-memory/config.json (written by /obsidian-memory:setup)

Storage layout inside the vault:
  <vault>/claude-memory/
      Index.md                 ← human-readable index (append-only link list)
      sessions/<slug>/*.md     ← distilled session notes (one per session)
      projects → ~/.claude/projects   (symlink; raw JSONL transcripts browsable in Obsidian)
```

No server component. No network calls on the hot path. The only subprocess spawned by a hook is `claude -p`, which the user has already authenticated.

---

## Technology Stack

| Layer | Technology | Version |
|-------|------------|---------|
| Hook scripts | Bash (POSIX-leaning) | `#!/usr/bin/env bash`; must run under macOS default bash (3.2) and Linux bash 4+ |
| Plugin manifest | Claude Code plugin schema | `plugin.json`, `hooks.json`, SKILL.md |
| Text search (fast path) | ripgrep (`rg`) | any recent version |
| Text search (fallback) | POSIX `grep -r` + `find` | base utilities; no GNU extensions required |
| JSON handling | `jq` | ≥ 1.6 |
| Distillation subprocess | Claude CLI (`claude`) | latest stable; invoked as `claude -p` with `CLAUDECODE=""` in the env |
| Optional MCP integration | [obsidian-claude-code-mcp](https://github.com/iansinnott/obsidian-claude-code-mcp) | registered at user scope by `/obsidian-memory:setup` on opt-in |
| Embedding backend (opt-in) | [ollama](https://ollama.com) + `nomic-embed-text` | any; opt-in for embedding backend. macOS: `brew install ollama && ollama pull nomic-embed-text`. Linux: `curl -fsSL https://ollama.com/install.sh \| sh && ollama pull nomic-embed-text`. Required only when `rag.backend = "embedding"`; the plugin never installs ollama. |
| HTTP client (opt-in) | `curl` | any; required only when `rag.backend = "embedding"` to reach the ollama HTTP API |
| Distribution | [nmg-plugins marketplace](https://github.com/Nunley-Media-Group/nmg-plugins) | user-scope install via `claude plugin install obsidian-memory` |

### External Services

None. obsidian-memory is local-first. The only external binary invoked is the already-authenticated `claude` CLI. ollama — used only when the user opts into `rag.backend = "embedding"` — remains local (`127.0.0.1:11434` by default); the plugin never contacts a SaaS endpoint.

---

## Versioning

The root-level `VERSION` file is the enforcement trigger that `nmg-sdlc`'s `/open-pr` skill reads to classify and apply version bumps. The `.claude-plugin/plugin.json` `version` field is dual-updated from the same source so the Claude Code marketplace reads the same value users install against. Both files must always agree.

| File | Path | Notes |
|------|------|-------|
| VERSION | entire file | Plain-text single-source-of-truth read by `/open-pr`. Without this file, `/open-pr` silently skips Steps 2 and 3 and no bump is applied. |
| .claude-plugin/plugin.json | `version` | Plugin manifest. Read by Claude Code at install and by every marketplace that references this repo. Dual-updated with `VERSION`. |
| CHANGELOG.md | `line:N` for `## [X.Y.Z]` heading | Conventional Changelog; the heading line changes per release. |

### Path Syntax

- **JSON files**: dot-notation (e.g., `version`, `plugins[0].version`).
- **Plain text files**: `line:N` where `N` is the line number of the version token.

### Version Bump Classification

The `/open-pr` skill and the `sdlc-runner.mjs` deterministic bump postcondition both read this table to classify version bumps. Modify this table to change the classification rules — no skill or script changes are needed.

| Label | Bump Type | Description |
|-------|-----------|-------------|
| `bug` | patch | Bug fix — backwards-compatible |
| `enhancement` | minor | New feature — backwards-compatible |
| `chore` | patch | Internal change with no user-visible behavior (docs, test-only, refactor without behavior change) |

**Default**: If an issue's labels do not match any row, the bump type is **minor**.

**Major bumps are manual-only.** A developer must opt in explicitly via `/open-pr #N --major`. In unattended mode, `--major` escalates and exits without bumping.

**Breaking changes use minor bumps while the plugin is pre-1.0.** Communicate the breaking nature via a `**BREAKING CHANGE:**` bold prefix on the affected CHANGELOG bullet and a `### Migration Notes` sub-section:

```markdown
## [0.3.0] - 2026-04-19

### Changed (BREAKING)

- **BREAKING CHANGE:** Renamed config key `rag.enabled` to `rag.enable`. Existing configs must be migrated.

### Migration Notes

In `~/.claude/obsidian-memory/config.json`, rename `rag.enabled` → `rag.enable` and `distill.enabled` → `distill.enable`. Running `/obsidian-memory:setup` does NOT perform the rename automatically.
```

---

## Technical Constraints

### Performance

| Metric | Target | Rationale |
|--------|--------|-----------|
| `vault-rag.sh` wall time on a 1k-note vault | < 300 ms p95 | UserPromptSubmit is on every prompt. Anything slower is user-visible latency. |
| `vault-distill.sh` wall time | Bounded only by `claude -p` | SessionEnd, not hot path; user has already left the session. Still, no polling loops. |
| RAG payload size | `<vault-context>` block ≤ 8 KB by default | Large payloads bloat the context window and dilute the user's actual prompt. |

### Security

| Requirement | Implementation |
|-------------|----------------|
| Authentication | None at the plugin level. `claude -p` inherits the user's existing CLI auth. |
| Authorization | Hooks only read from `<vault>` and `~/.claude/projects/`, and only write to `<vault>/claude-memory/`. Paths are read from config; the plugin never accepts paths from prompt content. |
| Secrets management | No secrets stored by the plugin. Config contains only a vault path and enable flags. |
| Input validation | Prompt text is never interpolated into shell commands. The RAG hook passes the prompt to `rg`/`grep` via stdin or `--` separated argv, never via command-string concatenation. When sending prompt text to the ollama HTTP API, the canonical form is `curl --data @- < body.json` (or piping a JSON body into `curl --data @-`) — prompt content lives in a JSON body read from stdin, never in an argv string. |
| Filesystem safety | All writes use absolute paths derived from `config.json`. Slugs for session filenames are `[a-z0-9-]`, collapsed and length-capped, so untrusted project names cannot escape the sessions directory. |

---

## Coding Standards

### Bash

```bash
# GOOD — fail loudly inside the script, but exit 0 at the hook boundary
set -u
trap 'log_err "vault-rag.sh failed at line $LINENO"; exit 0' ERR

VAULT="$(jq -r '.vault' "$CONFIG")"
if [ -z "$VAULT" ] || [ ! -d "$VAULT" ]; then
  exit 0   # silent no-op — hook must never block the user
fi

# GOOD — rg preferred, POSIX fallback always available
if command -v rg >/dev/null 2>&1; then
  rg --files-with-matches --glob '*.md' -- "$QUERY" "$VAULT"
else
  find "$VAULT" -type f -name '*.md' -print0 | xargs -0 grep -l -- "$QUERY"
fi

# BAD — `set -e` at a hook entry point can exit non-zero and confuse the caller
set -e

# BAD — interpolating user content into a shell command
eval "rg \"$QUERY\" \"$VAULT\""

# BAD — assuming rg is on PATH inside a hook subshell (editor-embedded rg is not)
rg "$QUERY" "$VAULT"
```

- Shebang: `#!/usr/bin/env bash`. No `#!/bin/bash`.
- Every top-level script has a `trap '... exit 0' ERR` so any unexpected failure still satisfies the "never block the user" principle.
- Use `$(…)`, never backticks. Quote every variable expansion that could contain spaces (`"$VAULT"`, not `$VAULT`).
- Prefer `[ … ]` over `[[ … ]]` when POSIX compatibility matters; `[[ … ]]` is fine inside hooks since the shebang forces bash.
- Indent with 2 spaces. No tabs.
- Function naming: `lower_snake_case`. Constants: `UPPER_SNAKE_CASE`.

### JSON (plugin manifests, config)

```json
{
  "name": "obsidian-memory",
  "version": "0.1.0"
}
```

- 2-space indentation. Trailing newline. No trailing commas.
- Field order in `plugin.json`: `name`, `version`, `description`, `author`, `repository`, `keywords`.

### Markdown (SKILL.md, README, steering, specs)

- ATX headings (`#`, `##`), no setext.
- Fenced code blocks with a language tag.
- Line length: no hard wrap; one sentence per line in long-form prose is acceptable.

---

## API / Interface Standards

obsidian-memory has no HTTP API. "Interfaces" means:

### Hook contracts

Every hook script is invoked by Claude Code per the `hooks/hooks.json` schema. The script:

1. Reads its payload from stdin as JSON (for hooks that provide one) or from documented env vars.
2. Writes its response, if any, to stdout per the Claude Code hook protocol.
3. Exits 0 on every terminating path — success, handled error, unrecognized state.
4. Logs unexpected failures to stderr (which Claude Code surfaces in the operator-visible hook log), never to stdout.

### Skill contracts

Every skill is a `SKILL.md` under `skills/<name>/SKILL.md`. Each has:

1. A frontmatter block declaring `name`, `description`, `version`.
2. A "When to Use" section.
3. An unambiguous invocation example (`/obsidian-memory:<name> <args>`).
4. Idempotency notes where relevant (e.g., `/obsidian-memory:setup` is safe to re-run).

---

## Database Standards

Not applicable. obsidian-memory has no database. All state is one of:

- `~/.claude/obsidian-memory/config.json` — flat JSON config.
- `<vault>/claude-memory/sessions/**/*.md` — append-only Markdown files.
- `<vault>/claude-memory/Index.md` — append-only index; links only, no semantic content.
- `<vault>/claude-memory/projects` — symlink to `~/.claude/projects` (the raw JSONL transcripts).

---

## Testing Standards

### BDD Testing (Required for nmg-sdlc)

**Every acceptance criterion MUST have a Gherkin scenario.**

| Layer | Framework | Location |
|-------|-----------|----------|
| BDD scenarios | cucumber-shell (shell-native Gherkin runner) | `specs/<feature-slug>/feature.gherkin` authored by `/write-spec`; step definitions under `tests/features/steps/*.sh` |
| Unit | [bats-core](https://github.com/bats-core/bats-core) | `tests/unit/*.bats` |
| Integration (end-to-end hook harness) | bats-core with a scratch `$HOME` and scratch vault | `tests/integration/*.bats` |

### Gherkin Feature Files

```gherkin
# specs/feature-<slug>/feature.gherkin
Feature: Vault RAG injects matching notes
  As a Claude Code + Obsidian user
  I want relevant prior notes surfaced on every prompt
  So that Claude answers with continuity across sessions

  Scenario: A vault note contains a keyword from the prompt
    Given an Obsidian vault at "$VAULT" containing "my-note.md" with the text "jq is used for config parsing"
    And   obsidian-memory is installed and setup against "$VAULT"
    When  the user submits a prompt containing "jq"
    Then  the UserPromptSubmit hook output contains a "<vault-context>" block
    And   the block contains "my-note.md"

  Scenario: Vault is empty
    Given an empty Obsidian vault at "$VAULT"
    And   obsidian-memory is installed and setup against "$VAULT"
    When  the user submits any prompt
    Then  the UserPromptSubmit hook exits 0
    And   the hook emits no "<vault-context>" block
```

### Step Definitions

```bash
# tests/features/steps/vault-rag.sh
# Conventions:
#   - One step definition per function; function names mirror the Given/When/Then phrasing.
#   - All filesystem state lives under $BATS_TEST_TMPDIR (scratch vault, scratch HOME).
#   - Never touch the operator's real ~/.claude or real Obsidian vault.

given_a_vault_at_containing_with_the_text() {
  local vault="$1" file="$2" text="$3"
  mkdir -p "$vault"
  printf '%s\n' "$text" > "$vault/$file"
}

when_the_user_submits_a_prompt_containing() {
  local query="$1"
  HOOK_INPUT=$(jq -n --arg q "$query" '{prompt: $q}')
  HOOK_OUTPUT=$(printf '%s' "$HOOK_INPUT" | "$PLUGIN_ROOT/hooks/vault-rag.sh")
}

then_the_hook_output_contains_a_vault_context_block() {
  echo "$HOOK_OUTPUT" | grep -q '<vault-context>'
}
```

### Unit Tests

| Type | Framework | Location | Run Command |
|------|-----------|----------|-------------|
| Unit | bats-core | `tests/unit/` | `bats tests/unit` |
| Integration | bats-core (with scratch `$HOME` + scratch vault) | `tests/integration/` | `bats tests/integration` |
| BDD | cucumber-shell | `specs/**/feature.gherkin` + `tests/features/steps/` | `tests/run-bdd.sh` |
| Static | shellcheck | every `*.sh` | `shellcheck scripts/*.sh tests/**/*.sh` |

### Test Pyramid

```
        /\
       /  \  BDD Integration (Gherkin, cucumber-shell)
      /----\  - Acceptance criteria for every spec
     /      \ - Full hook-invocation round-trips against a scratch vault
    /--------\
   /          \  bats integration tests
  /            \ - One scratch $HOME, one scratch vault, real scripts
 /--------------\
/                \  bats unit tests + shellcheck
 \________________/ - Pure-function shell helpers, slug sanitization, jq filters
```

---

## Verification Gates

The `/verify-code` skill enforces these as hard gates. Each gate specifies when it applies, what command to run, and how to determine success.

| Gate | Condition | Action | Pass Criteria |
|------|-----------|--------|---------------|
| Shellcheck | Always | `shellcheck scripts/*.sh tests/**/*.sh 2>/dev/null \|\| shellcheck $(find scripts tests -name '*.sh')` | Exit code 0 |
| Unit Tests | `tests/unit/` directory exists | `bats tests/unit` | Exit code 0 |
| Integration Tests | `tests/integration/` directory exists | `bats tests/integration` | Exit code 0 |
| BDD Tests | `specs/*/feature.gherkin` files exist | `tests/run-bdd.sh` | Exit code 0 |
| JSON validity | Always | `jq empty .claude-plugin/plugin.json hooks/hooks.json` | Exit code 0 |

### Condition Evaluation Rules

- `Always` — gate always applies
- `{path} directory exists` — gate applies only when the directory is present (`test -d {path}`)
- `{glob} files exist in {path}` — gate applies only when matching files are found in the given path

### Pass Criteria Evaluation Rules

- `Exit code 0` — the Action command must exit with code 0
- `{file} file generated` — the named file must exist after the Action command completes
- `output contains "{text}"` — stdout or stderr must contain the specified text
- Compound criteria use `AND` — all sub-criteria must be satisfied
- The `/verify-code` skill evaluates these textual criteria against actual results — no stack-specific logic is needed

---

## Environment Variables

### Required

None at install time. The plugin reads everything it needs from `~/.claude/obsidian-memory/config.json` once `/obsidian-memory:setup` has run.

### Used by the distillation hook

| Variable | Description |
|----------|-------------|
| `CLAUDECODE` | Cleared (`CLAUDECODE=""`) before spawning the nested `claude -p` so the inner CLI does not inherit the outer session's Claude Code sentinel. Required; without it, the nested invocation can loop or misbehave. |

### Used by tests

| Variable | Description |
|----------|-------------|
| `BATS_TEST_TMPDIR` | Provided by bats; test scratch directory. All test-written files live here. |
| `PLUGIN_ROOT` | Set by the bats test helper to the absolute path of the repo root. |

---

## References

- CLAUDE.md for project overview (if present)
- `steering/product.md` for product direction
- `steering/structure.md` for code organization
- Upstream marketplace: https://github.com/Nunley-Media-Group/nmg-plugins
