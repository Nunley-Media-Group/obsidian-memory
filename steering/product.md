# obsidian-memory Product Steering

This document defines the product vision, target users, and success metrics.
All feature development should align with these guidelines.

---

## Mission

**obsidian-memory makes Claude Code's memory persistent and browseable in an Obsidian vault by (1) keyword-searching the vault on every prompt and injecting matching notes as context, and (2) distilling each finished session into a dated Markdown note that links into the vault's index.**

It is a single Claude Code plugin, distributed via the [nmg-plugins](https://github.com/Nunley-Media-Group/nmg-plugins) marketplace. It is not itself a marketplace.

---

## Target Users

### Primary: Claude Code + Obsidian power user

| Characteristic | Implication |
|----------------|-------------|
| Uses Claude Code daily across many projects | Hooks must run on every project, every session, without per-project setup |
| Already curates an Obsidian vault as a "second brain" | Storage must be plain Markdown in a path the user controls |
| Expects local-first, inspectable tooling | No cloud dependency; every artifact is a file the user can read, edit, or delete |
| Values "never blocks me" over "always perfect" | Every hook must silently no-op on any failure (missing dep, missing config, disabled flag, empty input) |

### Secondary: AI-tooling tinkerer

| Characteristic | Implication |
|----------------|-------------|
| Wants hookable, plain-text memory rather than opaque server-side context | Retrieval and distillation must be replaceable script-level components |
| Will swap ripgrep for embeddings later | RAG must be a one-script swap — no hook-wiring changes needed to upgrade retrieval |
| Runs Claude Code on machines where `rg` may only be an editor-embedded wrapper | RAG script must fall back to POSIX `grep -r`/`find` automatically |

---

## Core Value Proposition

1. **Zero-config cross-session memory** — once `/obsidian-memory:setup <vault>` runs, every future Claude Code session on every project benefits from RAG on the vault and auto-distilled session notes, with no per-project wiring.
2. **Plain-Markdown, user-owned storage** — sessions land as dated Markdown files under `<vault>/claude-memory/sessions/<project-slug>/`, linked from `Index.md`. The user can read, edit, move, or delete them.
3. **Never blocks the user** — every hook exits 0 on any failure mode (missing dep, missing config, disabled flag, empty input). A broken hook must never stop a prompt or a session from ending cleanly.

---

## Product Principles

| Principle | Description |
|-----------|-------------|
| Local-first | No network calls on the hot path. The only subprocess the distill hook spawns is `claude -p`, which the user has already authenticated. |
| Silent failure | Any script failure exits 0 with no user-visible error. Failures log to stderr for operator inspection, never to the session UI. |
| Plain text > databases | Every artifact is a Markdown, JSON, or JSONL file at a known path. No SQLite, no embedded server. |
| One-script swaps | Retrieval (`vault-rag.sh`) and distillation (`vault-distill.sh`) are isolated scripts. Changing retrieval from keyword to embeddings must not touch `hooks.json` or any skill. |
| Idempotent setup | `/obsidian-memory:setup` is safe to re-run. It writes config, creates directories, and establishes symlinks only when missing. |

---

## Success Metrics

| Metric | Target | Why It Matters |
|--------|--------|----------------|
| RAG relevance on prompts where vault notes exist | Relevant notes surface on ≥60% of such prompts | The RAG hook is only valuable if it actually retrieves useful context. |
| Distillation correctness | 0 hallucinated decisions / patterns across a sampled audit of 20 session notes | Distillations are durable memory. A fabricated "decision" pollutes the vault permanently. |
| Hook safety | 0 reports of a hook blocking a prompt or session | The "silent failure" principle is load-bearing. One blocking hook destroys user trust. |
| Setup idempotency | `/obsidian-memory:setup` re-run 5× produces no drift in config, symlinks, or Index.md | Users re-run setup when changing vaults or machines. It must not accumulate state. |

---

## Feature Prioritization

### Must Have (MVP — v0.1.x, shipped)

- `UserPromptSubmit` keyword RAG hook with `ripgrep` + POSIX fallback
- `SessionEnd` distillation hook writing dated Markdown + Index.md linking
- `/obsidian-memory:setup` idempotent vault wiring (config, symlink, Index, optional MCP registration)
- `/obsidian-memory:distill-session` manual counterpart
- User-scope install; hooks apply to every project

### Should Have (v1 MVP scope for new work)

- CHANGELOG / release-automation for nmg-plugins marketplace listing
- Health-check skill: "is my obsidian-memory setup working?" (detects missing deps, bad config, broken symlink)
- `/obsidian-memory:teardown` or uninstall path that is the exact inverse of `setup`
- Disable-flag UX: clear docs + a skill that toggles `rag.enabled` / `distill.enabled` without editing JSON by hand

### Could Have

- Embedding-based retrieval swap for `vault-rag.sh`
- Per-project overrides (e.g., exclude a project from distillation)
- Configurable distillation template
- Cross-project search surface (a skill that searches all distilled sessions for a term)

A `v2` milestone is deliberately not created yet — every seeded candidate is in `v1 (MVP)` until MVP scope is closed.

### Won't Have (Now)

- Cloud sync or hosted backend — violates local-first
- Writing to the vault on every prompt (only SessionEnd writes) — cost and feedback-loop risk
- A custom Obsidian plugin on the Obsidian side — the MCP server already exists

---

## Key User Journeys

### Journey 1: First-time install

```
1. User adds the nmg-plugins marketplace and installs obsidian-memory.
2. User runs `/obsidian-memory:setup /path/to/vault`.
3. Setup writes config, creates claude-memory/sessions/, symlinks projects/, writes Index.md, optionally registers the MCP server.
4. User continues normal Claude Code usage; hooks activate on the next prompt / session end.
```

### Journey 2: Prompt with relevant prior context

```
1. User submits a prompt in a project they've worked on before.
2. UserPromptSubmit fires vault-rag.sh → keyword-matches the prompt against the vault.
3. Top matches are wrapped in a <vault-context> block and prepended to the prompt.
4. Claude sees the prior notes and answers with continuity.
```

### Journey 3: Session ends, distillation lands in the vault

```
1. User /exits or closes the Claude Code session.
2. SessionEnd fires vault-distill.sh → reads the JSONL transcript, invokes `claude -p` in a nested subprocess.
3. A note is written under <vault>/claude-memory/sessions/<project-slug>/YYYY-MM-DD-HHMMSS.md.
4. Index.md gets a link appended.
5. User opens Obsidian and can browse, edit, or link the distillation like any other note.
```

### Journey 4: Manual mid-session checkpoint

```
1. User hits a natural breakpoint mid-session and wants a snapshot.
2. User runs /obsidian-memory:distill-session.
3. The skill finds the newest JSONL under ~/.claude/projects/ and distills it identically to the SessionEnd hook.
4. The user continues; at session end the hook will produce a second, more complete distillation.
```

---

## Brand Voice

| Attribute | Do | Don't |
|-----------|-----|-------|
| Terse | "Writes `~/.claude/obsidian-memory/config.json`." | "This plugin will carefully write a configuration file to your home directory…" |
| Honest about limitations | "v0.1 uses keyword matching; embeddings are a later swap." | Claim semantic search or embeddings before they ship. |
| Operator-friendly | State exact paths, exact exit codes, exact commands. | Hand-wave with "just run setup." |

---

## Privacy Commitment

| Data | Usage | Shared |
|------|-------|--------|
| Prompt text (at UserPromptSubmit) | Local keyword-matched against the local vault to compose `<vault-context>`. | Never leaves the machine. |
| Session transcript (at SessionEnd) | Read from `~/.claude/projects/**/*.jsonl`, passed to a local `claude -p` subprocess for distillation. | Goes only to the Claude CLI subprocess that the user has already authenticated. |
| Distilled session notes | Written to the user's local Obsidian vault. | Only shared if the user syncs their vault (Obsidian Sync / iCloud / Git / etc.); not shared by this plugin. |
| Config (`~/.claude/obsidian-memory/config.json`) | Stores vault path and enabled flags. | Local-only. |

---

## References

- Technical spec: `steering/tech.md`
- Code structure: `steering/structure.md`
- Upstream marketplace: https://github.com/Nunley-Media-Group/nmg-plugins
- Obsidian MCP server: https://github.com/iansinnott/obsidian-claude-code-mcp
