# obsidian-memory Code Structure Steering

This document defines code organization, naming conventions, and patterns.
All code should follow these guidelines for consistency.

---

## Project Layout

```
obsidian-memory/                        # repo root IS the plugin root
├── .claude-plugin/
│   └── plugin.json                    # plugin manifest (name, version, description, keywords)
├── hooks/
│   └── hooks.json                     # hook → script wiring (UserPromptSubmit, SessionEnd)
├── scripts/
│   ├── _common.sh                     # shared preamble (config load, slug helper)
│   ├── vault-rag.sh                   # UserPromptSubmit: keyword RAG → <vault-context>
│   └── vault-distill.sh               # SessionEnd: distill transcript → dated vault note
├── skills/
│   ├── setup/
│   │   └── SKILL.md                   # /obsidian-memory:setup <vault-path>
│   └── distill-session/
│       └── SKILL.md                   # /obsidian-memory:distill-session (manual checkpoint)
├── specs/                             # nmg-sdlc specs (one dir per feature / bug)
│   └── <feature-slug>/
│       ├── requirements.md
│       ├── design.md
│       ├── tasks.md
│       └── feature.gherkin
├── steering/                          # THIS directory — product / tech / structure
│   ├── product.md
│   ├── tech.md
│   └── structure.md
├── tests/                             # bats + cucumber-shell
│   ├── unit/*.bats
│   ├── integration/*.bats
│   ├── features/steps/*.sh            # cucumber-shell step definitions
│   └── run-bdd.sh
├── CHANGELOG.md                       # Keep a Changelog + Conventional Commits
└── README.md
```

This repo is a **standalone plugin**. The plugin root is the repo root — `.claude-plugin/plugin.json`, `hooks/`, `scripts/`, and `skills/` are what Claude Code installs. Marketplace listings live in a separate upstream marketplace repo that references this one via `{ "source": { "source": "github", "repo": "Nunley-Media-Group/obsidian-memory" } }`. Everything else at the repo root (README, CHANGELOG, specs/, steering/, tests/) is development infrastructure and is not shipped to users.

---

## Layer Architecture

### Request / Data Flow — UserPromptSubmit

```
Claude Code prompt event
        ↓
┌──────────────────────┐
│  hooks.json          │ ← declares UserPromptSubmit → scripts/vault-rag.sh
└────────┬─────────────┘
         ↓
┌──────────────────────┐
│  vault-rag.sh        │ ← reads config, runs rg/grep, composes <vault-context>
└────────┬─────────────┘
         ↓ stdout (hook JSON response)
┌──────────────────────┐
│  Claude Code         │ ← merges <vault-context> into the prompt sent to the model
└──────────────────────┘
```

### Request / Data Flow — SessionEnd

```
Claude Code session-end event
        ↓
┌──────────────────────┐
│  hooks.json          │ ← declares SessionEnd → scripts/vault-distill.sh
└────────┬─────────────┘
         ↓
┌──────────────────────┐
│  vault-distill.sh    │ ← reads newest JSONL under ~/.claude/projects/
│                      │   spawns CLAUDECODE="" claude -p with a distillation prompt
│                      │   writes <vault>/claude-memory/sessions/<slug>/<ts>.md
│                      │   appends link to <vault>/claude-memory/Index.md
└──────────────────────┘
```

### Layer Responsibilities

| Layer | Does | Doesn't Do |
|-------|------|------------|
| `hooks.json` | Declaratively wires event → script. | Contain logic. Scripts do the work. |
| Hook scripts (`scripts/*.sh`) | Read config, guard against missing deps/config, do the work, emit protocol-compliant stdout, exit 0. | Read user prompts from anywhere other than hook stdin/env. Interpolate prompt text into shell commands. Ever exit non-zero at the top-level. |
| Skills (`skills/*/SKILL.md`) | Provide user-invocable commands for setup, manual distillation, health checks, teardown. | Run on every prompt — that's the hook's job. |
| Config file | Store vault path + enable flags. | Store credentials. Store per-project state. |
| `specs/` | Drive `/write-code` and `/verify-code`. | Get read at runtime by the plugin. Purely dev-time artifacts. |
| `steering/` | Constrain spec writing and code generation. | Get read at runtime. Purely dev-time. |

---

## Naming Conventions

### Bash

| Element | Convention | Example |
|---------|------------|---------|
| Files | `kebab-case.sh` | `vault-rag.sh`, `vault-distill.sh` |
| Functions | `lower_snake_case` | `read_config`, `emit_vault_context` |
| Local variables | `lower_snake_case` | `local vault_path="$1"` |
| Constants / env-like globals | `UPPER_SNAKE_CASE` | `CONFIG_PATH`, `PLUGIN_ROOT` |
| Exit codes | `0` for every terminating path at hook level. Internal helpers may return non-zero; the top-level script translates to 0. | — |

### JSON (manifests + config)

| Element | Convention | Example |
|---------|------------|---------|
| Top-level keys | `camelCase` in Claude Code manifests; `snake_case` in internal config | `"enabled": true`, `"vault_path": "..."` |
| File names | `kebab-case.json` | `plugin.json`, `hooks.json`, `config.json` |

### Markdown

| Element | Convention | Example |
|---------|------------|---------|
| Steering / README / CHANGELOG | `kebab-case.md` or conventional names | `product.md`, `README.md` |
| Spec directories | `specs/feature-<slug>/` or `specs/bug-<slug>/` | `specs/feature-health-check/` |
| Session distillations (inside vault) | `YYYY-MM-DD-HHMMSS.md` | `2026-04-19-143022.md` |
| Project slugs (for `sessions/<slug>/`) | `[a-z0-9-]`, collapsed, length-capped at 60 | `obsidian-memory` |

---

## File Templates

### Hook script template (`scripts/<hook>.sh`)

```bash
#!/usr/bin/env bash
# <hook>.sh — <one-line purpose>
#
# Invoked by Claude Code for the <EventName> event. Must exit 0 on every
# terminating path; failures log to stderr and silently no-op.

set -u

log_err() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
trap 'log_err "failed at line $LINENO"; exit 0' ERR

CONFIG="${HOME}/.claude/obsidian-memory/config.json"

# Guard: missing config → silent no-op
[ -f "$CONFIG" ] || exit 0

# Guard: feature disabled → silent no-op
enabled="$(jq -r '.<feature>.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
[ "$enabled" = "true" ] || exit 0

# Guard: required deps → silent no-op
command -v jq >/dev/null 2>&1 || { log_err "jq missing"; exit 0; }

# … do the work …

exit 0
```

### Skill template (`skills/<name>/SKILL.md`)

```markdown
---
name: obsidian-memory:<name>
description: <one-line what this skill does>
version: 0.1.0
---

# /obsidian-memory:<name>

<one-paragraph summary>

## When to Use

- <trigger 1>
- <trigger 2>

## When NOT to Use

- <anti-trigger>

## Invocation

```
/obsidian-memory:<name> <args>
```

## Behavior

1. <step>
2. <step>
3. <step>

## Idempotency

<explicit statement: is this skill safe to re-run? what does re-running do?>

## Error handling

<what the skill does on missing config, missing vault, missing deps>
```

---

## Import Order

### Bash

Scripts have no imports per se, but the conventional prelude is:

```bash
#!/usr/bin/env bash
# 1. Shebang + header comment
# 2. set -u (never set -e at hook entry points)
# 3. trap ERR → log + exit 0
# 4. Constants (CONFIG, PLUGIN_ROOT, etc.)
# 5. Function definitions (pure → composed)
# 6. Main entrypoint at the bottom
```

### JSON

No import order. Field order in manifests is fixed per `tech.md`.

---

## Design Tokens / UI Standards

Not applicable. obsidian-memory has no UI. Its "UI" is:

- A `<vault-context>` block prepended to prompts (schema: opaque Markdown body; no required attributes).
- A dated Markdown file in the vault (template: header / decisions / patterns / open threads / tags).
- The `Index.md` file (append-only bullet list of links).

---

## Anti-Patterns to Avoid

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `set -e` at a hook's top level | Causes the hook to exit non-zero on any unexpected command failure, blocking the user. | Use `set -u` and an `ERR` trap that logs and `exit 0`. |
| Assuming `rg` is on `PATH` inside a hook subshell | Editor-embedded ripgrep is often not exported to hook subshells. Hook silently fails on a fresh machine. | Always check `command -v rg`, fall back to POSIX `grep -r`/`find`. |
| Interpolating prompt content into a shell command | Classic shell-injection path; arbitrary prompt text can execute. | Pass via stdin or `argv` with `--` separators. Never compose a command string from untrusted input. |
| Writing to the vault on every prompt | RAG hot path writes would pollute the vault and create a feedback loop (next prompt reads what the last prompt wrote). | Only `SessionEnd` writes. `UserPromptSubmit` is read-only against the vault. |
| Indexing `claude-memory/projects/**` in RAG | The symlinked raw transcripts feed back into retrieval; next session's RAG picks up the last session's injected `<vault-context>` and re-injects it. | Hard-exclude `claude-memory/projects/**`, `.obsidian/**`, and `.trash/**` in the RAG glob. |
| Non-idempotent setup | Re-running `/obsidian-memory:setup` multiplies Index.md entries, duplicates MCP registrations, or rewrites working symlinks. | Every action in setup checks "does this already exist in the desired state?" before writing. Safe re-run is a success metric. |
| Reading the user's real `~/.claude` or real vault in tests | Tests can corrupt the operator's actual Claude Code state. | Always scope tests to `$BATS_TEST_TMPDIR`. Never read `$HOME` directly. |
| Not pinning the slug allowlist | Untrusted project names can contain path separators or `..` and escape the sessions directory. | Sanitize to `[a-z0-9-]`, collapse runs, cap length. Enforce in a single helper used by every writer. |

---

## References

- `steering/product.md` for product direction
- `steering/tech.md` for technical standards
- `README.md` for user-facing overview
- CHANGELOG.md for release history
