# Design: Per-Project Overrides (Exclude / Scope Config)

**Issues**: #6
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley

---

## Overview

This feature extends obsidian-memory's flat `config.json` with a `projects` stanza that gates the RAG and distillation hooks per-project without compromising the zero-per-project-config core value proposition (`steering/product.md` → CVP #1). A project is identified by the slug produced by the existing `om_slug` helper; the new policy (`mode`, `excluded`, `allowed`) is consulted by a single new helper (`om_project_allowed`) that both hooks call before doing work. When a project is scoped out, the hook silently no-ops — same exit-0 contract that governs every other failure mode in `steering/product.md` → "Never blocks the user."

Two surfaces get modified: the hot-path `scripts/_common.sh` (new helper, slug length cap) and the two hook scripts (`scripts/vault-rag.sh` and `scripts/vault-distill.sh`) which call the helper. Two surfaces get added: `scripts/vault-scope.sh` (the mutation script that owns the atomic write) and its thin-relayer skill `skills/scope/SKILL.md`. One additional hook (`SessionStart`) is wired so that mid-session scope edits cannot retroactively kill an in-flight session's distillation — the policy decision for a session is frozen at session start and replayed at session end.

The key architectural decision here is **where the policy gate lives**. Putting it in the `vault-rag.sh` dispatcher (not in the retrieval backends) preserves the "one-script swap" retrieval invariant from `steering/product.md` → Product Principles: adding an embedding backend, or swapping keyword for something else, does not require re-implementing the scope check. The distill hook gets the check inline because it has no dispatcher-backend split.

---

## Architecture

### Component Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              User Surface                                    │
│                                                                             │
│   /obsidian-memory:scope  ───────►  skills/scope/SKILL.md (thin relayer)    │
│                                                                             │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │
                                           ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                           Scripts Layer                                      │
│                                                                             │
│   scripts/vault-scope.sh  ──────►  atomic rewrite of .projects in config    │
│   scripts/vault-doctor.sh ──────►  read-only: new scope_mode probe          │
│                                                                             │
│   scripts/_common.sh                                                        │
│     ├─ om_load_config       (unchanged; still gates on vaultPath + enabled) │
│     ├─ om_slug              (MODIFIED: length-cap at 60)                    │
│     └─ om_project_allowed   (NEW: returns 0/1 per projects policy)          │
│                                                                             │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │
                                           ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                              Hooks Layer                                     │
│                                                                             │
│   SessionStart    ─►  scripts/vault-session-start.sh  (NEW — snapshots)     │
│   UserPromptSubmit ─►  scripts/vault-rag.sh           (gate before dispatch)│
│   SessionEnd      ─►  scripts/vault-distill.sh        (reads snapshot, then │
│                                                       gate, then distill)   │
│                                                                             │
└──────────────────────────────────────────┬──────────────────────────────────┘
                                           │
                                           ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                              On-Disk State                                   │
│                                                                             │
│   ~/.claude/obsidian-memory/config.json             (adds .projects stanza) │
│   ~/.claude/obsidian-memory/session-policy/*.state  (NEW — per-session     │
│                                                      policy snapshots)      │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow — UserPromptSubmit

```
1. Claude Code invokes vault-rag.sh with payload JSON on stdin.
2. vault-rag.sh sources _common.sh, calls om_load_config rag
   → exits 0 silently if config/vault/rag.enabled fails.
3. vault-rag.sh parses $CWD from payload (fallback: $PWD).
4. vault-rag.sh calls om_project_allowed "$CWD"
   → returns 1 if excluded or allowlist-miss; vault-rag.sh exits 0 with no stdout.
   → returns 0 if policy permits; flow continues.
5. vault-rag.sh reads rag.backend, dispatches to the matching backend script.
6. Backend emits <vault-context>…</vault-context> on stdout.
```

### Data Flow — SessionStart → SessionEnd

```
1. Claude Code invokes vault-session-start.sh (NEW) on SessionStart with session_id + cwd.
2. vault-session-start.sh computes the current policy outcome for this cwd and writes
   the single-line state file to ~/.claude/obsidian-memory/session-policy/<id>.state.
   Any failure path still exits 0 (never blocks).
3. Session proceeds normally.
4. Claude Code invokes vault-distill.sh on SessionEnd with session_id + cwd + transcript.
5. vault-distill.sh first looks for the <id>.state snapshot.
   a. If present with "excluded" or "allowlist-miss" → exit 0 silently (no distill).
   b. If present with "allowed" or "all" → proceed with existing distillation logic.
   c. If absent (session predates upgrade, or snapshot write failed) → fall back to
      live om_project_allowed "$CWD" against the CURRENT config (best-effort).
6. On any terminating path, vault-distill.sh removes the <id>.state file so stale
   snapshots do not accumulate.
```

---

## Data Model

### Extended `config.json`

```json
{
  "vaultPath": "/Users/me/Obsidian/MyVault",
  "rag": {
    "enabled": true,
    "backend": "keyword"
  },
  "distill": {
    "enabled": true
  },
  "projects": {
    "mode": "all",
    "excluded": [],
    "allowed": []
  }
}
```

Field semantics:

| Field | Type | Default (if stanza absent) | Meaning |
|-------|------|----------------------------|---------|
| `projects.mode` | `"all"` \| `"allowlist"` | `"all"` | `"all"` — every project allowed except those in `excluded`. `"allowlist"` — only projects in `allowed` are permitted; `excluded` is ignored but retained. |
| `projects.excluded` | `string[]` | `[]` | Slugs that are always denied (in `"all"` mode). Ignored in `"allowlist"` mode. |
| `projects.allowed` | `string[]` | `[]` | Slugs that are permitted (in `"allowlist"` mode). Ignored in `"all"` mode. |

Any other shape (`mode` is a string other than those two, `excluded`/`allowed` not an array) → treated as the default with a one-line stderr warning (AC7 / FR7).

### New snapshot file

`~/.claude/obsidian-memory/session-policy/<session_id>.state` — single-line plain-text file. One of:

- `all`
- `excluded`
- `allowlist-hit`
- `allowlist-miss`

The file is written at SessionStart and consumed/removed at SessionEnd. Directory is created on demand.

---

## API / Interface Changes

### New `om_project_allowed` helper (`scripts/_common.sh`)

```bash
# Return 0 if the current project is permitted by projects policy; 1 otherwise.
# Usage:  om_project_allowed "$CWD" || exit 0
#
# Reads .projects.{mode,excluded,allowed} from $CONFIG. Unknown/missing shape →
# treats as mode=all (permissive). Never exits on its own.
om_project_allowed() {
  local cwd="${1:-$PWD}"
  local slug
  slug="$(om_slug "$cwd")"
  [ -n "$slug" ] || return 0  # empty slug → permissive

  local mode excluded allowed
  IFS=$'\t' read -r mode excluded allowed < <(
    jq -r '
      [
        (.projects.mode // "all"),
        ((.projects.excluded // []) | @csv),
        ((.projects.allowed  // []) | @csv)
      ] | @tsv
    ' "$CONFIG" 2>/dev/null
  )
  mode="${mode:-all}"

  # Defense-in-depth: coerce unknown modes back to "all" with a stderr note.
  case "$mode" in
    all|allowlist) ;;
    *)
      printf '[%s] projects.mode=%q — treating as "all"\n' "$(basename "$0")" "$mode" >&2
      mode="all"
      ;;
  esac

  if [ "$mode" = "all" ]; then
    _om_slug_in_csv "$slug" "$excluded" && return 1
    return 0
  fi

  # mode = allowlist
  _om_slug_in_csv "$slug" "$allowed" && return 0
  return 1
}
```

`_om_slug_in_csv` is a small private helper that iterates the `@csv`-rendered list, handling jq's quoting so `"a","b"` splits cleanly. Not shown here — implementation detail for the task.

### New `om_policy_state` helper (`scripts/_common.sh`)

```bash
# Echo the policy outcome as one of: all | excluded | allowlist-hit | allowlist-miss.
# Used by vault-session-start.sh to write the snapshot.
om_policy_state() {
  local cwd="${1:-$PWD}"
  local slug mode excluded allowed
  slug="$(om_slug "$cwd")"
  [ -n "$slug" ] || { printf 'all\n'; return 0; }
  # … same jq read as om_project_allowed …
  if [ "$mode" = "all" ]; then
    _om_slug_in_csv "$slug" "$excluded" && { printf 'excluded\n'; return 0; }
    printf 'all\n'; return 0
  fi
  _om_slug_in_csv "$slug" "$allowed" && { printf 'allowlist-hit\n'; return 0; }
  printf 'allowlist-miss\n'
}
```

### Modified `om_slug` helper (`scripts/_common.sh`)

```bash
# basename($1), lowercased, non-alphanumerics → '-', collapsed, trimmed, length-capped at 60.
om_slug() {
  basename "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-|-$//g' \
    | cut -c1-60 \
    | sed -E 's/-$//'   # strip trailing hyphen that truncation may have exposed
}
```

The trailing-hyphen re-strip after `cut` handles the case where truncation lands exactly on a hyphen (e.g., a 61-character slug whose 60th char is `-`).

### New `scripts/vault-scope.sh`

Exit-code contract (mirrors `vault-toggle.sh`):

| Exit code | Meaning |
|-----------|---------|
| `0` | Success — status, successful mutation, or "no-op" (list already/did-not contain slug) |
| `1` | Runtime error — missing config, missing jq, failed atomic write |
| `2` | Bad usage — unknown verb, unknown mode value, too many arguments |

Argv grammar:

```
vault-scope.sh
vault-scope.sh status
vault-scope.sh current
vault-scope.sh mode (all|allowlist)
vault-scope.sh exclude (add|remove) [<slug>]
vault-scope.sh exclude list
vault-scope.sh allow   (add|remove) [<slug>]
vault-scope.sh allow   list
```

Atomic write pattern (verbatim from `vault-toggle.sh`):

```bash
TMP="$CONFIG.tmp.$$"
jq --indent 2 "<filter>" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
TMP=""  # cleanup trap leaves this alone on success
```

For `exclude add` the jq filter is `.projects.excluded = ((.projects.excluded // []) + [$slug] | unique)`.

### New `scripts/vault-session-start.sh`

```bash
#!/usr/bin/env bash
# vault-session-start.sh — SessionStart hook.
# Writes a one-line policy snapshot for this session_id so a mid-session
# scope edit does not retroactively kill an in-flight distill at SessionEnd.

. "$(dirname "$0")/_common.sh"

# No feature gate here — we still want snapshots even if rag/distill are
# individually toggled off, so a later toggle-on does not find the session
# in an ambiguous state.
PAYLOAD="$(om_read_payload)" || exit 0

IFS=$'\t' read -r SESSION_ID CWD < <(
  printf '%s' "$PAYLOAD" \
    | jq -r '[.session_id // "", .cwd // ""] | @tsv' 2>/dev/null
)
[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] || CWD="$(pwd)"

POLICY_DIR="${HOME}/.claude/obsidian-memory/session-policy"
mkdir -p "$POLICY_DIR" 2>/dev/null || exit 0

STATE="$(om_policy_state "$CWD")"
printf '%s\n' "$STATE" > "$POLICY_DIR/${SESSION_ID}.state" 2>/dev/null || exit 0

exit 0
```

### Modified `scripts/vault-rag.sh`

Gate insertion point is right after `om_load_config rag` and before dispatching to the backend:

```bash
. "$SCRIPT_DIR/_common.sh"
om_load_config rag

# Read cwd from the UserPromptSubmit payload; fall back to $PWD.
PAYLOAD="$(om_read_payload)" || exit 0
CWD_FROM_PAYLOAD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)"
CWD="${CWD_FROM_PAYLOAD:-$PWD}"

om_project_allowed "$CWD" || exit 0

# … existing payload-tee + backend dispatch continues unchanged …
```

The payload tee already exists downstream — this change only moves the payload read earlier so `$CWD` is available for the gate.

### Modified `scripts/vault-distill.sh`

Snapshot-first gate inserted after the payload parse, before the file-size / slug / write logic:

```bash
. "$(dirname "$0")/_common.sh"
om_load_config distill

PAYLOAD="$(om_read_payload)" || exit 0
IFS=$'\t' read -r TRANSCRIPT CWD SESSION_ID REASON < <(…)
[ -n "$CWD" ] || CWD="$(pwd)"

# Snapshot-first scope check — honors mid-session immunity (AC6).
POLICY_DIR="${HOME}/.claude/obsidian-memory/session-policy"
SNAPSHOT="$POLICY_DIR/${SESSION_ID}.state"
STATE=""
if [ -r "$SNAPSHOT" ]; then
  STATE="$(head -n1 "$SNAPSHOT" 2>/dev/null)"
  rm -f "$SNAPSHOT" 2>/dev/null
fi

case "$STATE" in
  excluded|allowlist-miss)
    exit 0  # honored the snapshot — session was scoped out at start
    ;;
  all|allowlist-hit)
    : # proceed below
    ;;
  *)
    # No snapshot or unrecognized content — fall back to live config.
    om_project_allowed "$CWD" || exit 0
    ;;
esac

# … existing distillation flow continues unchanged …
```

### Modified `scripts/vault-doctor.sh`

New probe added, same record-shape as existing INFO probes:

```bash
probe_scope_mode() {
  if [ "$_config_readable" -ne 1 ] || [ "$_jq_available" -ne 1 ]; then
    _record "scope_mode" "info" "cannot read — config or jq missing"
    return
  fi
  local mode excluded_n allowed_n
  IFS=$'\t' read -r mode excluded_n allowed_n < <(
    jq -r '[
      (.projects.mode // "all"),
      ((.projects.excluded // []) | length),
      ((.projects.allowed  // []) | length)
    ] | @tsv' "$CONFIG" 2>/dev/null
  )
  mode="${mode:-all}"
  if [ "$mode" = "all" ] && [ "${excluded_n:-0}" = "0" ]; then
    _record "scope_mode" "info" "all (unscoped)"
  else
    _record "scope_mode" "info" "$mode (excluded: ${excluded_n:-0}, allowed: ${allowed_n:-0})"
  fi
}
```

Registered in `main()` alongside the existing probes, between `probe_flag_enabled distill` and `probe_ripgrep`.

### Modified `hooks/hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/vault-session-start.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [ … unchanged … ],
    "SessionEnd":       [ … unchanged … ]
  }
}
```

---

## State Management

### Session policy snapshot

| Event | Reads | Writes |
|-------|-------|--------|
| SessionStart fires | `$CONFIG` (via `om_policy_state`) | `~/.claude/obsidian-memory/session-policy/<id>.state` |
| User edits scope mid-session | `$CONFIG` only | `$CONFIG` only |
| UserPromptSubmit fires mid-session | `$CONFIG` (live policy via `om_project_allowed`) | Nothing on the scope plane |
| SessionEnd fires | `<id>.state` first, then `$CONFIG` fallback | Removes `<id>.state`; writes session note only if permitted |

Note: UserPromptSubmit deliberately reads the **live** config — AC6's scope is SessionEnd / distillation. A user who excludes mid-session correctly stops RAG injection on the next prompt; that is desired behavior ("I want to stop leaking context right now"). What AC6 protects is the durable artifact — the distillation — from being killed by a mid-session edit.

### State transitions — scope skill

```
exclude add <slug>:
  projects.mode:      unchanged
  projects.excluded:  [...old...] ∪ {slug}
  projects.allowed:   unchanged

exclude remove <slug>:
  projects.excluded:  [...old...] \ {slug}   (no-op if absent)

mode allowlist:
  projects.mode:      "all" -> "allowlist"
  (warn if allowed is empty — every project is now scoped out)

mode all:
  projects.mode:      "allowlist" -> "all"
```

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Extend `/obsidian-memory:toggle`** | Add `exclude`/`allow`/`mode` verbs to toggle | One skill to learn | Dilutes toggle's "flip one boolean" contract; toggle's status output shape breaks; mode/list verbs don't map to the feature whitelist pattern | Rejected |
| **B: New `/obsidian-memory:scope` skill** | Dedicated skill backed by `vault-scope.sh` | Clean separation of concerns; atomic-write logic re-used from vault-toggle.sh; doctor/teardown pattern precedent | Slightly more code to ship (one more script, one more skill) | **Selected** |
| **C: Wildcard patterns in `allowed`/`excluded`** | Support e.g., `clients/*` | Expressive | v2 scope explicitly excludes this (issue body); adds a matching engine we don't need yet | Rejected (explicit out-of-scope) |
| **D: Snapshot stored in transcript directory** | Write `<id>.state` under `~/.claude/projects/<session>/` | Co-located with the JSONL transcript | Couples to Claude Code's internal layout; risk of our plugin polluting a directory we don't own | Rejected — keep snapshots under `~/.claude/obsidian-memory/session-policy/` |
| **E: Skip SessionStart hook; live-check at SessionEnd** | Simpler — one fewer hook | No SessionStart hook wiring, no snapshot files | Violates AC6: mid-session exclude would retroactively kill the in-flight distill | Rejected |
| **F: Length-cap om_slug in a new helper, leave old one alone** | Keep backward compat with any tests asserting the pre-cap behavior | Minimum diff | Creates two slug helpers with different guarantees — exactly the anti-pattern `steering/structure.md` warns against ("Not pinning the slug allowlist → single helper used by every writer") | Rejected — cap om_slug itself |
| **G: Scope gate inside vault-rag-keyword.sh / vault-rag-embedding.sh** | Push gate into backends | Gate decision visible in the code doing the work | Breaks the one-script-swap invariant; every new backend would need to re-implement the gate; drift risk | Rejected — gate lives in the dispatcher |

---

## Security Considerations

- **Slug canonicalization is the security boundary.** All three write paths (distill session directory, scope `exclude add`, scope `allow add`) pass through `om_slug`, which enforces `[a-z0-9-]`, collapse, and 60-char cap. An operator typing `scope exclude add ../../etc` ends up with `etc` (or similar) in the list — it cannot escape to an arbitrary path because the slug is only compared to another slug, never used as a filesystem path directly (`steering/tech.md` → Security → "Filesystem safety").
- **No prompt-content interpolation.** The cwd passed to `om_project_allowed` comes from the hook payload (Claude Code-provided JSON field, not the user-typed prompt). Even if an attacker crafted a prompt claiming a different cwd, the hook reads `.cwd` from the structured payload — the field is not set by prompt content.
- **Atomic writes (FR5).** `jq` renders to a sibling temp file, `mv` commits atomically on the same filesystem. A SIGKILL between `jq` and `mv` leaves the original config intact. An `EXIT` trap removes stray temp files.
- **Snapshot files contain no sensitive data.** One ASCII word per file (`all` / `excluded` / `allowlist-hit` / `allowlist-miss`). Deleted at SessionEnd.

---

## Performance Considerations

- **Extra jq invocation on the hot path.** `om_project_allowed` adds one `jq -r` read per hook invocation. Empirically, `jq` on a ~1 KB config takes ~5–10 ms on typical hardware. The p95 < 300 ms budget on UserPromptSubmit (`steering/tech.md` → Performance) has ample headroom.
- **Excluded projects are strictly faster.** When the gate returns 1, the hook skips the `rg`/`grep` walk entirely — net win on excluded projects.
- **No caching.** The config is small and read fresh each time. No cache invalidation headache; fresh-read keeps the live-vs-snapshot distinction crisp.
- **Snapshot I/O is trivial.** One small write at SessionStart, one small read + unlink at SessionEnd. Order of microseconds; invisible against the existing `claude -p` subprocess cost.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| `om_slug` (length cap, trailing-hyphen-after-truncate) | Unit (bats) | `tests/unit/common.bats` — assert cap at 60, stable output, trailing-hyphen handling |
| `om_project_allowed` (mode all, mode allowlist, malformed config) | Unit (bats) | `tests/unit/common.bats` — scratch config, every branch of the mode decision tree |
| `om_policy_state` (returns one of the four states) | Unit (bats) | `tests/unit/common.bats` — one test per state |
| `vault-scope.sh` (every verb + error path) | Unit (bats) | `tests/unit/vault-scope.bats` — scratch HOME; assert exit codes, stdout, stderr, config byte-diff |
| `vault-scope.sh` atomic write | Integration (bats) | `tests/integration/vault-scope-atomic.bats` — kill mid-write (or simulate jq failure), assert original config intact |
| RAG hook skips excluded project | Integration (bats) | `tests/integration/vault-rag-scope.bats` — scratch vault with matching note; assert no `<vault-context>` when excluded |
| Distill hook honors snapshot | Integration (bats) | `tests/integration/vault-distill-scope.bats` — write snapshot with `excluded`; assert no session file |
| Mid-session immunity (AC6) | Integration (bats) | snapshot predates a mid-session config edit; assert distill proceeds per the snapshot, not the live config |
| Doctor `scope_mode` probe | Integration (bats) | `tests/integration/doctor-scope.bats` — human + `--json` output shape |
| BDD scenarios for every AC | BDD (cucumber-shell) | `specs/feature-add-per-project-overrides-exclude-scope-config/feature.gherkin` + `tests/features/steps/vault-scope.sh` |
| Shellcheck | Static | All new/modified `.sh` files |

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| SessionStart hook is not honored by the Claude Code version the user is on | Low | Medium — mid-session immunity AC6 breaks gracefully: no snapshot → fall back to live config (AC6 wording admits the fallback behavior). Log an integration test that exercises the snapshot-missing branch. | FR9 explicitly requires the fallback. Document in release notes. |
| Truncating `om_slug` at 60 invalidates an existing user's distillation directory name | Low | Low | The cap only affects NEW slugs. Existing `sessions/<long-slug>/` directories keep their names. FR3 notes this in Out of Scope. |
| Slug collision between two distinct cwds that share the same basename (`/a/foo` and `/b/foo`) | Medium | Medium — user might exclude one "foo" and inadvertently exclude the other | Document in the skill's `When NOT to Use`: scope matches on slug, which is cwd-basename-derived. Recommend unique project directory names; this is already how distillation behaves today. |
| Mid-session edit races with SessionStart snapshot | Very low | Low | Snapshots are keyed by `session_id`; the only way to race is to start a session while another is ending. Different session IDs → different files; no contention. |
| User sets `mode=allowlist` with empty `allowed` | Medium | High — the plugin goes silent on every project | `vault-scope.sh mode allowlist` emits a stderr warning when `allowed` is empty: `WARNING: allowlist mode with no allowed projects — all projects will no-op`. Still exits 0; the user may want exactly this behavior temporarily. |
| Scope skill drift from toggle skill's atomic-write invariant | Low | Medium | Copy the exact `TMP` / `mv` / `EXIT` trap pattern from `vault-toggle.sh`. Task T00X explicitly cross-references the toggle script. |

---

## Open Questions

Resolved from requirements.md:

- **Snapshot persistence location**: decided on `~/.claude/obsidian-memory/session-policy/<session_id>.state`. Rationale is captured in Alternatives Considered → Option D.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #6 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Architecture follows existing project patterns (per `structure.md` — dispatcher + thin-relayer skills, hot-path guards in `_common.sh`)
- [x] All API/interface changes documented with signatures and filter shapes
- [x] Storage changes planned (new `projects` stanza; new snapshot directory)
- [x] State management approach is clear (live vs. snapshot distinction pinned)
- [x] Security considerations addressed (slug canonicalization, atomic write, no prompt-content interpolation)
- [x] Performance impact analyzed (extra jq read; short-circuit speedup when excluded)
- [x] Testing strategy defined (unit / integration / BDD layering)
- [x] Alternatives were considered and documented (A through G)
- [x] Risks identified with mitigations
