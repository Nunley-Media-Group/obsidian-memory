# Requirements: Configurable distillation template

**Issues**: #7
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian power user with a strong opinion on how my distilled session notes should read
**I want** to customize the Markdown template used by `vault-distill.sh`
**So that** my vault notes follow my existing conventions (frontmatter, tags, section order) instead of the plugin's opinionated default.

---

## Background

`scripts/vault-distill.sh` today generates notes using a single hardcoded prompt that instructs `claude -p` to emit a **Summary / Decisions / Patterns & Gotchas / Open Threads / Tags** layout. That is a reasonable default, but it is not universal — some users want frontmatter (dates, source links, status), different section names, or an entirely different layout matching their Daily Note / Zettelkasten / PARA workflow. Forcing those users to fork the script is incompatible with `steering/product.md` → Target Users → AI-tooling tinkerer ("retrieval and distillation must be replaceable script-level components").

`steering/product.md` → Feature Prioritization → Could Have names this capability explicitly: *"Configurable distillation template."* This spec promotes it into the v1 MVP scope.

The current state relevant to this work:

- `scripts/vault-distill.sh` embeds the distillation prompt inline as a single `PROMPT="..."` heredoc-style string with one interpolation (`${SLUG}` inside the `#project/<slug>` Tags line).
- The hook writes a hardcoded YAML frontmatter block (`date`, `time`, `session_id`, `project`, `cwd`, `end_reason`, `source: claude-code`) regardless of what `claude -p` produces.
- `~/.claude/obsidian-memory/config.json` is a flat JSON object with `vaultPath`, `rag.*`, `distill.*`, and (since #6) a `projects` stanza with `mode` / `excluded` / `allowed`. No template-related keys exist.
- `steering/tech.md` → Technology Stack pins `jq` ≥ 1.6 as a required dependency. `_common.sh` already uses `jq` for all config reads, so jq-based template variable substitution is in-stack and does not add a new dependency.
- The per-project override framework from #6 (merged in PR #18) ships `projects.{mode, excluded, allowed}` but does not ship a `projects.overrides` sub-key. This spec adds one, scoped to the template-path use case, without changing the shape of the existing scope policy fields.

**Missing-template behavior decision (AC3 / FR5).** The issue leaves AC3 open — the spec must pick **fallback to default** vs. **silent exit 0**. This spec picks **fallback to the bundled default template**, with a single stderr log line. Rationale:

1. `steering/product.md` → Product Principles → "Never blocks the user" requires the hook to exit 0, which both options satisfy.
2. Silent exit 0 would *also* throw away the session note — every session would be silently lost whenever the user's template path went stale (typo, file moved, permissions changed). That is a strictly worse outcome than receiving a correctly-formatted note in the default layout.
3. The bundled default template (FR4) is shipped inside the plugin and is always readable, so fallback cannot itself fail under any reasonable operator state.
4. Logging to stderr matches the existing hook pattern (`log_err` in the `_common.sh` preamble) — the operator can see the problem in the hook log without the user's session ever being affected.

**Template file format decision.** A template is a single Markdown file with two regions:

1. **Optional YAML frontmatter** at the very top, delimited by `---` lines. Variables are substituted inside this block. If the template has frontmatter, the hook emits **that** frontmatter (after substitution) and does **not** emit its own default seven-field block.
2. **Prompt body** — everything after the frontmatter, or the whole file if no frontmatter is present. Variables are substituted, then the body is sent to `claude -p` as the prompt. If the body contains the literal token `{{transcript}}`, the extracted conversation replaces that token; otherwise the conversation is appended after a blank line + `TRANSCRIPT:` label (preserving v0.1 behavior byte-for-byte when no marker is used).

This split lets AC5 be a clean "the frontmatter appears unchanged" check and keeps the prompt body flexible without forcing users to learn a second template format.

**Variable whitelist.** `project_slug`, `date`, `time`, `session_id`, `transcript_path`, `transcript`. The issue's FR3 lists the first five; `transcript` is added to support body-position control (AC4 stipulates the `{{...}}` syntax and FR3 stipulates the first five names — `transcript` is an additive token needed for the prompt to be functional without magic trailing-append behavior, documented here). All six are substituted via `jq --arg ... | gsub("\\{\\{name\\}\\}"; $name)` — literal string replacement with no shell, no `eval`, no `envsubst`. Any `{{other_name}}` token not in the whitelist is left as literal text in the output. Any `$VAR`, `` `cmd` ``, or `$(cmd)` syntax in the template is likewise never expanded.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: A user-provided template path overrides the default

**Given** `distill.template_path` in `~/.claude/obsidian-memory/config.json` points at a readable Markdown file with a custom layout (for example, sections `## What Happened`, `## Next`, `## Links`)
**And** setup has been run against `$VAULT`
**And** `distill.enabled=true`
**When** a `SessionEnd` event fires with a transcript ≥ 2 KB
**Then** the prompt sent to `claude -p` is the contents of the configured template (with whitelisted variables substituted)
**And** the resulting session note under `<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` follows the structure described by the template
**And** the hook exits 0.

**Example**:
- Given: `/path/to/my-template.md` contains `# {{project_slug}} — {{date}}\n\n## What Happened\n\n{{transcript}}`
- When: session ends with `transcript_path=/tmp/t.jsonl`, `cwd=/Users/me/code/widgets`
- Then: the prompt sent to claude is `# widgets — 2026-04-22\n\n## What Happened\n\n<conversation text>`

### AC2: Default behavior unchanged when no template is configured

**Given** `distill.template_path` is absent from config (or the whole `distill` stanza contains only `enabled`)
**And** setup has been run against `$VAULT`
**And** `distill.enabled=true`
**When** a `SessionEnd` event fires with a transcript ≥ 2 KB
**Then** the prompt sent to `claude -p` is byte-for-byte identical to the prompt `vault-distill.sh` emitted at v0.1 (modulo `${SLUG}` → `{{project_slug}}` substitution of the one slug reference)
**And** the emitted file frontmatter is the v0.1 seven-field block (`date`, `time`, `session_id`, `project`, `cwd`, `end_reason`, `source`)
**And** the `<VAULT>/claude-memory/Index.md` link format is unchanged.

**Example**: running with no `distill.template_path` in config must produce, when compared against a v0.1 run of the same transcript with a fixed `claude -p` stub, an identical note except for wall-clock-dependent timestamp fields.

### AC3: Missing or unreadable template falls back to the default

**Given** `distill.template_path` points at a file that does not exist, is not readable (permissions), or is empty
**And** `distill.enabled=true`
**When** a `SessionEnd` event fires with a transcript ≥ 2 KB
**Then** the hook writes a single stderr line of the form `[vault-distill.sh] distill.template_path=<path> unreadable; falling back to default template`
**And** the hook falls back to the bundled default template at `<plugin-root>/templates/default-distillation.md`
**And** the session note is written as if no template had been configured
**And** the hook exits 0.

### AC4: Template variables are substituted safely

**Given** a template containing the tokens `{{project_slug}}`, `{{date}}`, `{{time}}`, `{{session_id}}`, `{{transcript_path}}`, and `{{transcript}}`
**And** a template containing shell-looking syntax like `$HOME`, `` `whoami` ``, `$(date)`, `${PATH}`, and a non-whitelisted token `{{user_email}}`
**When** the hook substitutes variables before sending the prompt to `claude -p`
**Then** each of the six whitelisted tokens is replaced with its corresponding sanitized value (exact replacement, not pattern-expanded)
**And** `$HOME`, backticks, `$()`, `${…}`, and `{{user_email}}` appear in the substituted prompt verbatim (never expanded or resolved)
**And** no subprocess other than the single `claude -p` call is spawned as a side effect of substitution.

**Example**:
- Template body: `# {{project_slug}} on {{date}} — see {{transcript_path}}\n$HOME should be literal\n{{user_email}} stays a placeholder`
- Substituted (for slug=`widgets`, date=`2026-04-22`, transcript_path=`/tmp/t.jsonl`): `# widgets on 2026-04-22 — see /tmp/t.jsonl\n$HOME should be literal\n{{user_email}} stays a placeholder`

### AC5: Custom frontmatter is preserved in the output

**Given** a template whose first characters are a YAML frontmatter block, e.g.:
```
---
title: "{{project_slug}} — {{date}}"
tags: [daily-note]
source: claude-code
---

# Summary

{{transcript}}
```
**When** the distilled note is written
**Then** the output file begins with exactly that frontmatter block (with `{{project_slug}}` and `{{date}}` substituted) followed by a single blank line and then the body produced by `claude -p`
**And** the hook does **not** emit its own default seven-field frontmatter in addition to the template's
**And** no additional frontmatter key is inserted or removed.

---

## Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR1 | Add `distill.template_path` to the config schema — optional string, interpreted as an absolute path. | Must | Written by the user (or by a future `/obsidian-memory:setup` flag); never inferred from prompt content. |
| FR2 | When `distill.template_path` is set and the file is readable and non-empty, `vault-distill.sh` uses that file as the distillation prompt template (after variable substitution) instead of the hardcoded inline prompt. | Must | Resolution order: per-project override (FR8) > global `distill.template_path` > bundled default. |
| FR3 | Substitute only the whitelist `{project_slug, date, time, session_id, transcript_path, transcript}` using `jq --arg … \| gsub("\\{\\{name\\}\\}"; $name)`. No `eval`, no `envsubst`, no shell expansion of `$VAR` / backticks / `$(…)` / `${…}`. Non-whitelist `{{…}}` tokens pass through verbatim. | Must | All six values are pre-sanitized: `project_slug` is `[a-z0-9-]` per `om_slug`; `date`/`time` are generated from `date -u`; `session_id` and `transcript_path` come from the hook payload; `transcript` is the already-truncated JSONL extraction. |
| FR4 | Ship the current default template as a visible file at `templates/default-distillation.md` in the plugin root. Document that copying it to `~/.claude/obsidian-memory/templates/my-template.md` and pointing `distill.template_path` at the copy is the supported customization flow. | Must | The default template is the source of truth for AC2 — the hardcoded prompt string in `vault-distill.sh` is removed; the default template file becomes the sole definition of v0.1 layout. |
| FR5 | Missing-template behavior on an unreadable / empty / nonexistent `distill.template_path`: log one stderr line and fall back to the bundled default. Never exit non-zero, never skip the distillation. | Must | See Background → Missing-template behavior decision for rationale. |
| FR6 | The existing distillation BDD scenarios (#11, referenced from `specs/feature-session-distillation-hook/feature.gherkin`) must continue to pass. The default-template path (no `distill.template_path` configured) and the explicitly-configured-default-template path (`distill.template_path=<plugin-root>/templates/default-distillation.md`) must both satisfy AC2 with the same observable output. | Must | Adds one new scenario per path to this feature's Gherkin; does not rewrite the #11 Gherkin. |
| FR7 | `/obsidian-memory:doctor` (feature-doctor-health-check-skill) reports which template is in use: either `default (bundled)`, `global: <path>`, `project-override(<slug>): <path>`, or `configured but unreadable — falling back to default`. | Should | Lives in the doctor skill's output; this spec only requires the field is present and the string format is one of the four listed. |
| FR8 | Per-project template override via `projects.overrides.<slug>.distill.template_path` — when set and readable, takes precedence over `distill.template_path` for that project slug. | Could | Depends on #6 per-project overrides framework (already landed via PR #18). FR8 uses the `projects.overrides` sub-key to avoid shape collision with `projects.{mode, excluded, allowed}` — the `overrides` sub-key is new. |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | Template load + substitution must add < 50 ms to the distill hook's wall time. Far below the hook's `claude -p` dominant cost; primarily a guardrail against pathological templates. The variable-substitution pass is a single `jq` invocation. |
| **Security** | `distill.template_path` is read as a local file path only. No URL schemes. No `..` traversal guard is required because the path comes from config (operator-controlled, never from prompt content), consistent with `steering/tech.md` → Security → "paths are read from config; the plugin never accepts paths from prompt content." Variable substitution uses `jq gsub` literal replacement — no interpretation of template content as shell or code. |
| **Accessibility** | N/A — no UI surface. |
| **Reliability** | Every hook exit path remains `exit 0`. A malformed template (syntactically valid UTF-8 but nonsensical content) produces whatever `claude -p` yields for it; the hook does not validate template content. Bundled default is immutable during install and guaranteed readable — fallback cannot fail. |
| **Platforms** | macOS default bash 3.2 + Linux bash 4+, per `steering/tech.md`. The substitution implementation must not rely on bash 4+ features (no `${var//pat/rep}` over heredocs; use `jq`). |

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `distill.template_path` | string | Must be a readable regular file when set. Absolute path recommended; relative paths are resolved against `$HOME`. | No |
| `projects.overrides.<slug>.distill.template_path` | string | Same validation as above. `<slug>` must match `[a-z0-9-]{1,60}` (the `om_slug` output charset). | No |
| Template file | UTF-8 text | File must be non-empty. Optional YAML frontmatter must be delimited by exactly two `---` lines (first non-whitespace line is `---`, and the matching closing `---` appears before any other `---` line). | Yes when `template_path` is set |

### Output Data

| Field | Type | Description |
|-------|------|-------------|
| Session note file | Markdown | `<VAULT>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md`. Frontmatter is either (a) the template's frontmatter after variable substitution (AC5), or (b) the hook's default seven-field block (AC2). Body is `claude -p` output. |
| Stderr log line | text | Emitted only when the configured template is unreadable; format pinned in AC3. |
| Index line | Markdown | Unchanged from v0.1: `- [[sessions/<slug>/<ts>.md]] — <slug> (<date> <time> UTC)`. |

---

## Dependencies

### Internal Dependencies

- [x] `scripts/_common.sh` — slug helper, config loader, per-project policy readers.
- [x] `scripts/vault-distill.sh` — the hook this spec modifies.
- [x] `projects.{mode,excluded,allowed}` config stanza from #6 — unchanged; this spec adds a sibling `projects.overrides` sub-key.

### External Dependencies

- [x] `jq` ≥ 1.6 — already required (`steering/tech.md`).
- [x] `claude` CLI — already required.

### Blocked By

- [ ] Issue #1 — the BDD harness (bats-core + cucumber-shell) is required to execute AC2 (byte-for-byte prompt-equivalence) and AC4 (substitution safety) in CI. Implementation of this spec can proceed without #1; verification requires it.

---

## Out of Scope

- A DSL for multi-template composition (e.g., one template for coding sessions, another for planning sessions). Single template per config scope is sufficient for v1.
- Live preview / editing UI for templates.
- Bundled alternate templates (Daily Note, PARA, Zettelkasten, etc.) — one default plus the "copy and edit" pattern is sufficient.
- Template includes / partials (`{{> header}}`) — the template is a single file.
- Hot-reload of the template within a single session — `SessionEnd` reads the path fresh on each invocation, which is enough.
- Validating template content for well-formed Markdown or YAML frontmatter — garbage in, garbage out; `claude -p` handles most malformations gracefully and the spec does not attempt to.
- Changing the output file path or the Index.md line format — both remain pinned to the #11 baseline.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Default-path parity | 100% of default-path runs produce a prompt byte-identical to the v0.1 prompt (modulo `{{project_slug}}` expansion) | AC2 BDD scenario compares the prompt string against a golden fixture checked in at `tests/fixtures/distill/v0.1-prompt.txt`. |
| Fallback silence | 0 user-visible errors when `distill.template_path` points at a bad file across 5 repeated SessionEnd events | AC3 BDD scenario; stderr log lines are captured but not surfaced to the user. |
| Substitution safety | 0 instances of shell-syntax expansion (`$VAR`, backticks, `$(…)`) when those tokens appear literally in a template | AC4 BDD scenario with a template that intentionally contains each form. |

---

## Open Questions

- [ ] Should `/obsidian-memory:setup` grow a `--template-path=<path>` flag that writes `distill.template_path` into config? The issue doesn't demand it; FR7 (doctor reports it) plus hand-editing config is enough for v1. Deferred unless setup spec amendment wants it.
- [ ] Should a global `templates/` directory under `~/.claude/obsidian-memory/` be implicitly searched when `distill.template_path` is a bare filename? Decided: no — paths in config are absolute; `$HOME` is the only relative base. Keeps the resolution rule one line.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #7 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to PLAN phase:

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details bleed into the ACs (design.md picks the jq-gsub mechanism; ACs pin only the observable behavior)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases and error states are specified (AC3, AC4, AC5)
- [x] Dependencies are identified (#1 for BDD verification; #6 for the overrides key shape)
- [x] Out of scope is defined
- [x] Open questions are documented (template-path flag for setup; implicit `~/.claude/obsidian-memory/templates/` search — deferred)
