# Design: Configurable distillation template

**Issues**: #7
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley

---

## Overview

This design adds a single new seam to `scripts/vault-distill.sh`: the distillation prompt is no longer hardcoded — it is loaded from a Markdown template file, resolved in a deterministic order (per-project override > global `distill.template_path` > bundled default), variable-substituted via `jq gsub`, and optionally parsed for YAML frontmatter that the hook emits verbatim into the output file.

The change is deliberately localized. Template loading, variable substitution, and frontmatter extraction become three new helper functions in `scripts/_common.sh` (where the existing config / slug / policy helpers already live). The hook body loses 20 lines of inline prompt construction and gains 4 lines of helper calls. A new top-level directory, `templates/`, ships a single file (`default-distillation.md`) that is the sole source of truth for the v0.1 layout — the current hardcoded prompt string is *removed*, not duplicated, to prevent drift between "the default" and "the default template."

The design rejects three tempting but inferior alternatives: (1) `envsubst` (unsafe — expands any `$VAR` the template contains), (2) bash `${var//pattern/replacement}` inside a heredoc (macOS bash 3.2 compatibility risk and requires escaping), and (3) a Mustache-style Python/Node helper (new dependency, violates `steering/tech.md` stack constraints). `jq --rawfile | gsub` is the only approach that is both in-stack and provably shell-safe — the template content is read into a jq string and never reaches a shell interpreter.

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    Claude Code SessionEnd event                   │
└──────────────────────────────┬──────────────────────────────────┘
                               │  (payload JSON on stdin)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                   scripts/vault-distill.sh                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ 1. om_load_config distill  (existing)                     │  │
│  │ 2. om_read_payload         (existing)                     │  │
│  │ 3. Per-project scope gate  (existing, from #6)            │  │
│  │ 4. Transcript size guard   (existing)                     │  │
│  │ 5. Slug + timestamp derivation (existing)                 │  │
│  │ 6. Extract CONVO via jq    (existing)                     │  │
│  │                                                            │  │
│  │ === NEW in #7: ============================================= │  │
│  │ 7. template_path = om_resolve_distill_template "$SLUG"     │  │
│  │ 8. tmpl_raw      = cat "$template_path" (or default file)  │  │
│  │ 9. (fm, body)    = om_split_frontmatter "$tmpl_raw"        │  │
│  │ 10. fm_out       = om_render "$fm"   (jq gsub)             │  │
│  │ 11. prompt_out   = om_render "$body" (jq gsub)             │  │
│  │ === /NEW =================================================== │  │
│  │                                                            │  │
│  │ 12. NOTE_BODY = CLAUDECODE="" claude -p "$prompt_out"      │  │
│  │ 13. Emit file:  fm_out (or default frontmatter) + NOTE_BODY│  │
│  │ 14. Update Index.md (existing)                             │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
┌──────────────────────┐    ┌──────────────────────────┐
│  scripts/_common.sh  │    │  templates/              │
│  (new helpers)       │    │    default-distillation  │
│  - om_resolve_...    │    │    .md                   │
│  - om_split_fm       │    │  (FR4 — visible file)    │
│  - om_render         │    └──────────────────────────┘
└──────────────────────┘
```

### Data Flow

```
1. Hook loads config, validates payload, reads transcript (unchanged).
2. Hook calls om_resolve_distill_template "$SLUG":
     - Reads config.projects.overrides[slug].distill.template_path → if set+readable+nonempty: use it.
     - Reads config.distill.template_path                         → if set+readable+nonempty: use it.
     - Falls back to $PLUGIN_ROOT/templates/default-distillation.md.
     - On "set but unreadable/empty", logs one stderr line and returns the bundled default.
3. Hook cats the resolved file into $TMPL_RAW.
4. Hook calls om_split_frontmatter "$TMPL_RAW" to produce $FM_RAW and $BODY_RAW.
     - If the first non-blank line is `---` and a closing `---` exists later → split.
     - Otherwise $FM_RAW="" and $BODY_RAW = $TMPL_RAW.
5. Hook calls om_render on each region with the variable whitelist:
     - jq -Rn --rawfile tmpl … --arg project_slug $SLUG … --arg transcript $CONVO
              '$tmpl | gsub("\\{\\{project_slug\\}\\}"; $project_slug) | gsub…'
     - Each whitelisted placeholder is replaced literally; non-whitelisted {{x}} pass through.
6. Hook sends $PROMPT_OUT to `claude -p`.
7. Hook writes the note file:
     - If $FM_OUT is non-empty → emit $FM_OUT + "\n" + NOTE_BODY.
     - Else                     → emit the legacy 7-field frontmatter + "\n" + NOTE_BODY.
8. Hook appends the Index.md link line (unchanged).
```

---

## API / Interface Changes

### New helper functions in `scripts/_common.sh`

| Function | Signature | Purpose |
|----------|-----------|---------|
| `om_resolve_distill_template` | `om_resolve_distill_template "$slug" → echoes absolute path to template file` | Resolves per-project → global → bundled-default. Logs to stderr and returns the bundled default on "configured but unreadable." Never returns non-zero unless no usable template exists (which is impossible because the bundled default ships in the plugin). |
| `om_split_frontmatter` | `om_split_frontmatter "$tmpl_raw" → prints FM block (may be empty), a 0-byte separator, then BODY block` | Splits a template file's content into (optional) YAML frontmatter and body. Uses awk (POSIX) — no bash 4+ features. Produces output via a separator so the caller can read both halves. |
| `om_render` | `om_render "$text" → prints text with whitelisted `{{name}}` tokens replaced` | Invokes `jq -Rn --rawfile` with the six `--arg` values. Safe under any template content (no shell interpretation). Reads the expected vars from its environment (`SLUG`, `NOW_DATE`, `NOW_TIME`, `SESSION_ID`, `TRANSCRIPT`, `CONVO`) so the hook does not have to enumerate them at each call site. |

### New public config keys

```json
{
  "distill": {
    "enabled": true,
    "template_path": "/Users/me/.claude/obsidian-memory/templates/my-daily-note.md"
  },
  "projects": {
    "mode": "all",
    "excluded": [],
    "allowed": [],
    "overrides": {
      "widgets": {
        "distill": {
          "template_path": "/Users/me/.claude/obsidian-memory/templates/work-note.md"
        }
      }
    }
  }
}
```

- `distill.template_path` (string, optional) — absolute path, or relative path resolved against `$HOME`.
- `projects.overrides.<slug>.distill.template_path` (string, optional) — same shape, per-project. The `overrides` sub-key is new in this spec; it sits *beside* `projects.{mode, excluded, allowed}` (the scope-policy stanza from #6) without touching them.

### No CLI / HTTP / hook-payload changes

The `SessionEnd` hook payload contract is unchanged. No new environment variables are introduced. No new required configuration — everything added is optional with backwards-compatible defaults.

---

## Database / Storage Changes

Not applicable — obsidian-memory has no database. The only storage changes are:

| Location | Change |
|----------|--------|
| `templates/default-distillation.md` | **New file** at the plugin root, containing the v0.1 prompt text with `{{project_slug}}` substituted in the one place `${SLUG}` currently appears. Shipped as part of the plugin. |
| `scripts/_common.sh` | **Modified**: three new helper functions appended at the bottom (does not touch existing helpers). |
| `scripts/vault-distill.sh` | **Modified**: removes the inline `PROMPT="..."` heredoc; replaces with helper calls. |
| `~/.claude/obsidian-memory/config.json` | **Schema extension** (additive): new optional keys. Existing configs remain valid without any migration. |

---

## State Management

Not applicable — there is no client-side or server-side state beyond the config file, which is read fresh on each hook invocation (snapshot already handled by `vault-session-start.sh` for scope policy; templates are NOT snapshotted because a mid-session template edit has no in-flight effect — `SessionEnd` is a single point-read, not a streaming state).

---

## UI Components

Not applicable — the plugin has no UI. The only user-visible surfaces are:

- The config JSON file (edited by hand or via `/obsidian-memory:setup`).
- The doctor skill output (FR7 reports which template is in use).
- The session notes themselves (obviously).

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: `envsubst`** | Read template, pipe through `envsubst '$project_slug $date …'` with only whitelisted vars allowed. | Familiar Unix tool, single-pipeline substitution. | `envsubst` with no arg list expands *every* `$VAR` it sees. With an arg list it still does not escape backticks or `$(…)` in POSIX shells that pre-expand. A template containing ``` `rm -rf ~` ``` becomes a hazard the moment anyone copy-pastes a template off the internet. Also adds a new dependency not listed in `steering/tech.md`. | Rejected — security. |
| **B: bash `${var//pat/rep}` over a heredoc** | Read template into a bash variable, run six `${tmpl//\{\{name\}\}/$val}` expansions. | Zero new deps, in-stack. | macOS default bash 3.2 supports the syntax but mishandles multi-line heredocs with `\r`; quoting rules around `{{}}` in patterns are error-prone; single-char-at-a-time bash string ops are O(n²) on 10 KB templates. | Rejected — correctness and platform risk. |
| **C: Python / Node Mustache helper** | Invoke a small Python or Node script to render the template with a strict context dict. | Cleanest substitution semantics; Mustache is industry-standard. | Adds a new runtime dependency not in `steering/tech.md`; breaks the "zero-network, one-subprocess" simplicity; increases install surface. | Rejected — scope. |
| **D: `jq --rawfile | gsub`** | Read the template as a raw jq string, chain six `gsub` calls for the whitelist. | jq is already a pinned dep (≥1.6); `gsub` is literal regex replacement with no shell interpretation; single subprocess; output goes to stdout unchanged. `--rawfile` treats the file as an opaque string so no escaping is needed in either direction. | Slightly harder to read than Mustache; escape sequences in `gsub` patterns need `\\{\\{` to quote the literal braces. | **Selected**. |

The template-format shape — Markdown with optional frontmatter — was also considered against alternatives:

| Option | Description | Decision |
|--------|-------------|----------|
| Plain text body only (no frontmatter-as-output) | Template is just the prompt; the hook always emits its own frontmatter. | Rejected — breaks AC5; a user wanting a custom frontmatter would have to hand-edit files after the fact. |
| Two separate files (prompt + frontmatter template) | `distill.prompt_path` + `distill.frontmatter_path`. | Rejected — two knobs for one concept; doubles the failure surface (AC3 would now need to specify behavior when one is readable and the other is not). |
| Frontmatter is the default; body is optional | Invert the current proposal — template is primarily a frontmatter definition; the prompt defaults to the v0.1 prompt unless `{{prompt}}` is present. | Rejected — conflates two unrelated concerns. |
| **Markdown file with optional `---` frontmatter** | What the design uses. Frontmatter is opt-in via `---` delimiters; the body is the prompt. | **Selected**. |

---

## Security Considerations

- [x] **Authentication**: No change — the plugin has no auth layer.
- [x] **Authorization**: Template paths come from `~/.claude/obsidian-memory/config.json`, which is operator-controlled. The plugin never accepts a template path from prompt content or hook payload, consistent with `steering/tech.md` → Security → "paths are read from config; the plugin never accepts paths from prompt content."
- [x] **Input Validation**: The template path is checked for `-r` (readable regular file) and `-s` (non-empty). No content validation beyond that — the template is opaque text to the hook.
- [x] **Data Sanitization**: The substitution whitelist is the only write of user-controlled data into the prompt. Each whitelisted value is either pre-sanitized by the plugin (slug) or comes from Claude Code's own `SessionEnd` payload (session_id, transcript_path) and is embedded as a jq string (`--arg`), never as argv text for an intermediate shell.
- [x] **Sensitive Data**: The conversation transcript is already capped at ~200 KB by the existing hook. This spec does not loosen that cap. Templates are local files — no network transmission.
- [x] **Code Injection**: The design's principal risk is "can a malicious template cause shell execution?" The answer is no by construction — the template file is read via `cat` (into a jq-managed string), never via `eval` or a heredoc that the shell re-scans. The only subprocess spawned after substitution is `claude -p`, which receives the rendered prompt as a single argv string.

---

## Performance Considerations

- [x] **Caching**: None needed — `SessionEnd` fires once per session; the template is read once per invocation. No hot-path concern.
- [x] **Pagination**: N/A.
- [x] **Lazy Loading**: N/A.
- [x] **Indexing**: N/A.
- [x] **Latency budget**: The added work per invocation is one stat + one file read + one awk split + two jq invocations (`om_render` for frontmatter and for body). On a 10 KB template this runs in < 30 ms on typical hardware — well under the 50 ms NFR, and rounding error against `claude -p`'s multi-second dominant cost.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Variable substitution | Unit (bats) | Every whitelist var replaced; non-whitelist `{{x}}` preserved; `$VAR`, backticks, `$(…)`, `${…}` preserved; multi-occurrence replacement; templates containing `{{` or `}}` stray braces. |
| Frontmatter split | Unit (bats) | No frontmatter → empty FM, full body; frontmatter present → FM captured, body after `---`; malformed (opening `---` without closing) → treat as body, no FM. |
| Template resolution | Unit (bats) | Per-project override wins; global wins when no override; default wins when neither is set; unreadable path falls back with stderr log; empty file falls back with stderr log. |
| End-to-end default path | BDD (cucumber-shell) | AC2 — run hook with no `template_path` set, confirm prompt byte-identity against the golden fixture. |
| End-to-end custom path | BDD | AC1 — run hook with a custom template, confirm the emitted file's structure matches the template. |
| End-to-end fallback | BDD | AC3 — run hook with a bad `template_path`, confirm one stderr line + fallback + exit 0. |
| End-to-end safety | BDD | AC4 — run hook with a template containing `$HOME`, backticks, `$(…)`, `{{user_email}}`; confirm none are expanded. |
| End-to-end frontmatter | BDD | AC5 — run hook with a template that has a YAML frontmatter; confirm the output frontmatter matches (post-substitution). |

All BDD tests use the existing scratch `$VAULT` / scratch `$HOME` / `claude -p` stub pattern established by #11's test suite. The `claude -p` stub produces deterministic output keyed on the prompt hash, so AC1/AC2/AC5 can assert file structure against golden fixtures.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Default-template drift — the bundled file diverges from the v0.1 hardcoded string, silently breaking AC2. | Medium (new file, new temptation to "improve" it) | High (silent change to every default-path user's notes) | (a) Remove the inline prompt string from `vault-distill.sh` in the same task that creates the template file — there is no second source of truth to diverge from. (b) Pin a golden-fixture byte-hash assertion in the AC2 BDD scenario so any future template-file edit surfaces as a failing test. |
| Variable-substitution regex footgun — a future helper author uses an unescaped `.` or `+` in a gsub pattern and inadvertently matches outside the whitelist. | Low (jq gsub is regex) | Medium (could let a non-whitelisted token through) | Pin the gsub pattern shape in `_common.sh` to the literal `\\{\\{<name>\\}\\}` — one helper with a fixed pattern template, not ad-hoc regexes at each call site. Unit test covers a template containing `{{project_slugger}}` to confirm it does not get partially substituted. |
| jq 1.5 on older Linux distributions — `--rawfile` landed in jq 1.5 but behavior on binary/invalid-UTF-8 content varied between 1.5 and 1.6. | Low (`steering/tech.md` pins ≥ 1.6 already) | Low | Keep the minimum-version check in `_common.sh`'s `command -v jq` guard as-is; document in the skill that templates must be UTF-8 (which is already the Markdown convention). |
| Per-project override slug mismatch — user sets `projects.overrides.my_project.*` with an underscore, but `om_slug` produces `my-project`. | Medium | Low (override is silently ignored) | The doctor skill (FR7) reports the active template, which surfaces the mismatch. Additionally, `om_resolve_distill_template` logs at `debug` verbosity when a per-project override key is present but the computed slug does not match any override. |
| Frontmatter detection false positive — a template whose body happens to start with `---` (e.g., a horizontal rule followed by Markdown) is mis-parsed as having frontmatter. | Low | Low (frontmatter block looks weird; substitution still works) | Detection requires the first non-blank line to be exactly `---` AND a later line to be exactly `---`. A horizontal rule after content would not match (no leading `---`). Documented in the skill and covered by a dedicated unit test. |

---

## Open Questions

- [ ] Should `om_render` also substitute an `{{hostname}}` token for users who want per-machine notes? Deferred — the whitelist is explicitly locked per FR3, and the issue's use cases don't require it.
- [ ] Does the per-project override lookup need to run once per hook invocation, or can it be cached? Deferred — the hook runs once per session; caching inside a single run adds complexity for zero measurable benefit.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #7 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Architecture follows existing project patterns (helpers in `_common.sh`, one modified hook, no new dependencies)
- [x] All API/interface changes documented (three new helpers, two new optional config keys)
- [x] Storage changes planned (one new top-level `templates/` dir, one new file, `_common.sh` + `vault-distill.sh` modifications)
- [x] State management approach is clear (none — stateless per invocation)
- [x] UI components addressed (N/A, no UI)
- [x] Security considerations addressed (jq literal substitution, no shell interpretation, paths from operator-controlled config only)
- [x] Performance impact analyzed (< 50 ms added; negligible vs `claude -p` dominant cost)
- [x] Testing strategy defined (unit + BDD across every AC)
- [x] Alternatives were considered and documented (`envsubst`, bash param expansion, Mustache helper, jq gsub — and four template-format shapes)
- [x] Risks identified with mitigations (default drift, regex footgun, jq version, slug mismatch, false-positive frontmatter)
