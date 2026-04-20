# Design: Vault setup skill

**Issues**: #9
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Overview

`/obsidian-memory:setup` is a Claude Code skill (Markdown + frontmatter at `plugins/obsidian-memory/skills/setup/SKILL.md`) whose job is to bootstrap the cross-cutting config + vault layout that the two hook scripts (`vault-rag.sh`, `vault-distill.sh`) read at runtime. The skill produces **four artefacts** and optionally one external side effect (MCP registration). Every action is guarded by an "already in the desired state?" check so re-running is idempotent — this is the load-bearing property of the skill.

The skill intentionally keeps control flow in Markdown (executed by the Claude Code skill runtime) rather than a dedicated shell script. This lets the skill compose `Bash`, `Read`, `Write`, `Edit`, and `AskUserQuestion` tools as needed without building a custom shell for conditional edits of an existing JSON config. The hook scripts are plain Bash because they are on the hot path; the skill is one-off and benefits from the skill runtime's orchestration.

---

## Architecture

### Component Diagram

Per `steering/structure.md`, the plugin has three tiers: `hooks/` (declarative wiring), `scripts/` (hook workers), and `skills/` (user-invocable commands). Setup lives in the **skill tier** and writes artefacts that the hook-script tier reads.

```
┌─────────────────────────────────────────────────────────────────┐
│                 Claude Code skill runtime                       │
│  ┌────────────────────────────────────────────────────────┐     │
│  │  plugins/obsidian-memory/skills/setup/SKILL.md         │     │
│  │    · Resolve vault path                                │     │
│  │    · Write/merge config.json                           │     │
│  │    · mkdir claude-memory/sessions                      │     │
│  │    · Create/repoint projects symlink                   │     │
│  │    · Initialize Index.md                               │     │
│  │    · Optional MCP registration                         │     │
│  │    · Dependency check + smoke test                     │     │
│  └────────────────────────────────────────────────────────┘     │
└──────────────┬──────────────┬──────────────┬───────────────────┘
               │              │              │
               ▼              ▼              ▼
     ┌──────────────────┐ ┌───────────┐ ┌──────────────────┐
     │ ~/.claude/       │ │ <vault>/  │ │ claude mcp add   │
     │ obsidian-memory/ │ │ claude-   │ │ -s user obsidian │
     │ config.json      │ │ memory/   │ │ (optional)       │
     └──────────────────┘ └───────────┘ └──────────────────┘
                                │
                                ├── sessions/ (dir)
                                ├── projects → ~/.claude/projects (symlink)
                                └── Index.md
```

### Data Flow

```
1. User invokes: /obsidian-memory:setup <vault-path>
2. Skill reads $1 (or prompts via AskUserQuestion) and expands ~
3. Skill verifies the directory exists; aborts with a clear message if not
4. Skill reads existing config.json (if present), merges in vaultPath
5. Skill ensures claude-memory/sessions/ exists
6. Skill inspects <vault>/claude-memory/projects:
   - absent → ln -s ~/.claude/projects
   - symlink to ~/.claude/projects → leave
   - symlink elsewhere → ln -sfn to repoint
   - regular file/dir → refuse, instruct user
7. Skill initializes Index.md if absent; leaves alone otherwise
8. Skill prompts for MCP registration; runs claude mcp add on Yes
9. Skill checks deps (jq, rg, claude) and smoke-tests vault-rag.sh
10. Skill prints final report
```

---

## API / Interface Changes

### Skill contract (per `tech.md`)

**Invocation:** `/obsidian-memory:setup <vault-path>`

**Frontmatter** (`plugins/obsidian-memory/skills/setup/SKILL.md`):

```yaml
name: setup
description: One-time, idempotent setup for the obsidian-memory plugin. …
argument-hint: <vault-path>
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
model: sonnet
effort: low
```

### Config schema written by setup

```json
{
  "vaultPath": "/absolute/path/to/vault",
  "rag":     { "enabled": true },
  "distill": { "enabled": true }
}
```

Extra top-level keys already present in an existing file are preserved on re-run. Only `vaultPath` is overwritten.

### Internal shell commands used

| Command | Purpose |
|---------|---------|
| `mkdir -p "$HOME/.claude/obsidian-memory"` | Ensure config parent |
| `mkdir -p "<vault>/claude-memory/sessions"` | Ensure sessions dir |
| `ln -s "$HOME/.claude/projects" "<vault>/claude-memory/projects"` | Create symlink |
| `ln -sfn "$HOME/.claude/projects" "<vault>/claude-memory/projects"` | Repoint stale symlink |
| `test -L`, `test -e`, `readlink` | Distinguish symlink vs regular file |
| `command -v jq`, `command -v rg`, `command -v claude` | Dependency probe |
| `claude mcp add -s user obsidian --transport websocket ws://localhost:22360` | Optional MCP registration |
| `printf '{"prompt":"test setup keyword search"}' \| …/vault-rag.sh` | Smoke test |

---

## Database / Storage Changes

No database. All state is on the filesystem under two roots:

| Root | Owner | Writes |
|------|-------|--------|
| `~/.claude/obsidian-memory/` | This plugin | `config.json` (created/merged) |
| `<vault>/claude-memory/` | Shared with user | `sessions/` (mkdir), `projects` (symlink), `Index.md` (only if absent) |

No migration is needed for v0.1.0 — this is the initial baseline.

---

## State Management

The skill is stateless across invocations. All "state" is derived fresh at run-time from:

- `$1` (argv) or `AskUserQuestion` response
- `~/.claude/obsidian-memory/config.json` (if present — merged, not blindly overwritten)
- Filesystem probes (`test -L`, `readlink`) against `<vault>/claude-memory/`

No in-memory state survives between runs. Re-run behavior is entirely driven by filesystem checks before each mutation.

---

## UI Components

Not applicable. The skill's surface area is:

- The terminal-style output of each Bash tool call as rendered by Claude Code
- One `AskUserQuestion` modal for MCP registration (Yes / No / Skip)
- The final report (stdout)

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Dedicated shell script (`scripts/setup.sh`)** | Move all setup logic into a Bash script, reduce SKILL.md to a thin invocation wrapper | Scriptable outside Claude Code; easier to unit-test in bats | Loses access to `AskUserQuestion`; harder to do conditional JSON merges without additional deps | Rejected — `AskUserQuestion` for MCP opt-in and merge-preserving JSON edits justify keeping orchestration in the skill |
| **B: Require the vault to be created by setup** | Have setup `mkdir -p "$VAULT"` if missing | Smooth first-run UX | Creating an Obsidian vault in the wrong filesystem location is destructive and irreversible from the user's perspective | Rejected — vaults are user-owned; setup aborts on missing vault (AC3) |
| **C: Current design — skill-orchestrated, idempotent, abort-on-missing-vault** | What ships in v0.1.0 | Idempotent; preserves user state; uses native `AskUserQuestion`; explicit about what it refuses to touch | More logic in Markdown than pure code | **Selected** |

---

## Security Considerations

- [x] **Authentication**: None at plugin level. `claude mcp add` inherits the user's existing CLI auth.
- [x] **Authorization**: Writes strictly under `~/.claude/obsidian-memory/` and `<vault>/claude-memory/`. The skill does not accept file paths from prompt content — only from `$1` or `AskUserQuestion` responses.
- [x] **Input Validation**: Vault path is verified to exist with `test -d` before any write. Leading `~` is expanded via `$HOME`, never via `eval`.
- [x] **Data Sanitization**: The skill does not sanitize the vault path beyond directory-existence; any valid directory is accepted. Shell-metacharacters in the vault path are safely quoted by skill-runtime Bash tool usage.
- [x] **Sensitive Data**: Config contains only a vault path and two boolean flags; no credentials.
- [x] **Filesystem safety**: Setup refuses to delete non-symlink entries at `<vault>/claude-memory/projects` (AC4). The only deletion it performs is the atomic `ln -sfn` repoint of a symlink (AC5).

---

## Performance Considerations

- [x] **Caching**: None needed.
- [x] **Smoke-test cost**: `vault-rag.sh` with a 1-keyword payload against an empty vault completes in < 100 ms; negligible.
- [x] **Interactive prompt**: `AskUserQuestion` for MCP registration dominates wall-clock time; NFR excludes it.

---

## Testing Strategy

Reference `tech.md` — the project uses bats-core for unit/integration and cucumber-shell for BDD.

| Layer | Type | Coverage |
|-------|------|----------|
| Skill runtime | Integration (bats, scratch `$HOME` + scratch vault) | Full setup invocation from a clean state — verifies all 4 artefacts (AC1) |
| Idempotency | Integration | Run setup twice; diff artefact state; assert no drift (AC2, success metric) |
| Error paths | Integration | Missing vault (AC3), non-symlink `projects` (AC4), stale symlink (AC5), missing `jq`/`claude` (AC8) |
| MCP registration | Integration with stub `claude` binary | Yes-path (AC6) and Skip-path (AC7) |
| BDD | cucumber-shell | All 8 ACs as scenarios in `specs/feature-vault-setup/feature.gherkin` |

A dedicated `setup.sh` does not exist, so unit-testing the skill directly is not in scope; integration tests through the skill runtime are authoritative.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| User points setup at a path that is not actually their Obsidian vault (e.g., a random directory) | Medium | Medium | AC3 only verifies existence; we document in `product.md` that the vault is user-owned. Future `/obsidian-memory:doctor` (#2) can cross-check for `.obsidian/` presence |
| Re-running setup with a changed vault path silently moves the config | Low | Medium | `vaultPath` is overwritten on re-run (FR2); this is the intended migration path when changing vaults. Documented in the skill description |
| `claude mcp add` partially succeeds (registers but immediately fails to connect) | Low | Low | AC6 treats `claude mcp add` exit as non-fatal and reports; failure does not corrupt other setup steps |
| `Index.md` is later edited into an invalid shape | Low | Low | Setup leaves existing Index.md untouched (FR5); the distill hook's `awk` append is best-effort and exits 0 on any parse issue |
| `rg` is installed but not on the hook subshell `PATH` | Medium | Low | Smoke test in FR8 runs the actual hook; if `rg` is only editor-embedded, the fallback path still satisfies the smoke test |

---

## Open Questions

- [ ] None — this documents shipped behavior.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #9 | 2026-04-19 | Initial baseline design — documents v0.1.0 shipped behavior |

---

## Validation Checklist

- [x] Architecture follows existing project patterns (per `structure.md`)
- [x] All API/interface changes documented with schemas
- [x] Database/storage changes planned with migrations (N/A — no DB)
- [x] State management approach is clear (stateless; filesystem-derived)
- [x] UI components and hierarchy defined (N/A — CLI)
- [x] Security considerations addressed
- [x] Performance impact analyzed
- [x] Testing strategy defined
- [x] Alternatives were considered and documented
- [x] Risks identified with mitigations
