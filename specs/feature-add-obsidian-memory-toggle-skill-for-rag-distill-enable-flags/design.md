# Design: Toggle Skill for rag/distill Enable Flags

**Issues**: #4
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## Overview

The toggle skill is a thin user-facing wrapper around a single shell script that reads and writes `~/.claude/obsidian-memory/config.json`. The skill itself (`skills/toggle/SKILL.md`) carries only enough Markdown to explain the command and its flags; all behavior — arg parsing, whitelist enforcement, atomic write — lives in `scripts/vault-toggle.sh`. This split follows the pattern already used by `skills/doctor/` → `scripts/vault-doctor.sh` and `skills/teardown/` → `scripts/vault-teardown.sh`, keeping every code path deterministically testable under `bats` without a live Claude session.

Unlike hook scripts, `vault-toggle.sh` is user-invoked and must **surface errors**: a missing config, an unknown feature, or a failed write are all non-zero exits with diagnostic stderr. This is the same stance `vault-doctor.sh` takes and the opposite of the hook scripts' silent-failure contract — the user invoked toggle expecting feedback. Accordingly, the script does **not** source `_common.sh::om_load_config`, which would mask those errors by exiting 0 (see Alternatives Considered → Option C).

Writes go through `jq --indent 2` into a same-directory temp file followed by `mv` — the standard atomic-write idiom on a single filesystem. The config is never truncated or opened `O_TRUNC` in place; a SIGKILL between `jq` and `mv` leaves the original config intact, and the temp file is cleaned up by an `EXIT` trap so failed runs never leave `.tmp` droppings.

---

## Architecture

### Component Diagram

```
┌────────────────────────────────────────────────────────────┐
│  User invokes /obsidian-memory:toggle [<feature> [<state>]]│
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  skills/toggle/SKILL.md                                    │
│   - documents command, flags, exit codes, examples         │
│   - instructs Claude to run scripts/vault-toggle.sh "$@"   │
│   - relays exit code + stdout/stderr verbatim              │
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  scripts/vault-toggle.sh                                   │
│   - parse argv (0, 1, or 2 positional args)                │
│   - enforce feature whitelist (rag | distill)              │
│   - dispatch: status | show-then-flip | set-explicit       │
│   - atomic write via temp file + mv                        │
│   - exit 0 on success; 1 on user/config error; 2 on bad    │
│     usage                                                  │
└──────────┬─────────────────────────────────────────────────┘
           │   READ + WRITE (single file)
           ▼
┌────────────────────────────────────────────────────────────┐
│  ~/.claude/obsidian-memory/config.json                     │
└────────────────────────────────────────────────────────────┘
```

### Data Flow

```
1. SKILL.md receives invocation → shells out to scripts/vault-toggle.sh "$@"
2. vault-toggle.sh:
   a. Parse argv into (feature, state) tuple.
      - 0 args OR first arg == "status"  → mode = status
      - 1 arg (feature only)             → mode = flip
      - 2 args (feature + state)         → mode = set
   b. Validate feature ∈ {rag, distill}; any other value → usage + exit 2.
   c. Validate state against alias table (mode=set only); unknown → usage + exit 2.
   d. Verify config exists and is readable; else ERROR + exit 1.
   e. For mode=status: read both flags via jq; print; exit 0.
   f. For mode=flip: read current value; compute inverse; fall through to write.
   g. For mode=set: if new value equals current → print "was already" + exit 0.
   h. Write: jq rewrite to "$CONFIG.tmp.$$"; mv to "$CONFIG"; print prev -> new.
   i. EXIT trap removes any leftover "$CONFIG.tmp.$$" on failure.
3. Exit code propagates through the skill → user.
```

### Layer Responsibilities

Per `steering/structure.md`:

| Layer | Role in this feature |
|-------|----------------------|
| Skill (`skills/toggle/SKILL.md`) | User entry point; declarative. No logic. |
| Script (`scripts/vault-toggle.sh`) | All logic. Reads argv, reads/writes config, formats output, chooses exit code. |
| Config file (`~/.claude/obsidian-memory/config.json`) | The only mutable state. Written atomically; every non-touched key preserved. |

---

## API / Interface Changes

### New: `scripts/vault-toggle.sh`

Command-line interface:

```
vault-toggle.sh                     # status, shorthand
vault-toggle.sh status              # status, explicit
vault-toggle.sh <feature>           # flip current value
vault-toggle.sh <feature> <state>   # set explicit

<feature> ::= rag | distill
<state>   ::= on | off | true | false | 1 | 0 | yes | no   (case-insensitive)
```

Exit codes:

| Exit code | Meaning |
|-----------|---------|
| 0 | Success — includes status, successful mutation, and the "was already" no-op. |
| 1 | Runtime error — config missing, config unreadable, `jq` missing, atomic-write failure. |
| 2 | Bad usage — unknown feature, unknown state alias, too many args. |

Stdout (success):

```
# status / shorthand
rag.enabled: true
distill.enabled: false

# mutation
rag.enabled: true -> false

# already in state
rag.enabled was already true
```

Stderr (error, first line always `ERROR:` for machine parsing):

```
ERROR: config not found — run /obsidian-memory:setup <vault> first
ERROR: unknown feature 'foobar' — allowed: rag, distill
ERROR: unknown state 'maybe' — allowed: on, off, true, false, 1, 0, yes, no
ERROR: jq missing — install jq (brew install jq)
ERROR: failed to write config
```

### New: `skills/toggle/SKILL.md`

Skill frontmatter follows the convention used by `skills/doctor/SKILL.md`:

```markdown
---
name: toggle
description: Flip rag.enabled / distill.enabled in obsidian-memory's config without hand-editing JSON. Use when the user says "disable rag", "enable distill", "turn off obsidian memory hook", "toggle rag", or invokes /obsidian-memory:toggle.
argument-hint: [<feature> [<state>]]
allowed-tools: Bash, Read
model: sonnet
effort: low
---
```

Body covers: When to Use, When NOT to Use, Invocation, Behavior (relay only), Exit Code Contract, Related skills. Mirrors the `doctor` SKILL body style so consumers see consistent structure across the plugin's skills.

---

## Database / Storage Changes

No schema change. The config file already has `rag.enabled` and `distill.enabled` booleans; toggle mutates them in place.

Key-preservation rules:

- `jq --indent 2 '.<feature>.enabled = <bool>'` writes only the target key.
- Every sibling and nested key — `vaultPath`, any user-added `customFoo`, future additions — round-trips unchanged because `jq` reads the whole document and re-emits it.
- Key ordering is preserved in practice (jq preserves insertion order); this is not part of the contract but makes diffs clean.

---

## State Management

Not applicable — this is a one-shot CLI. No in-memory state outlives the script invocation.

---

## UI Components

Not applicable — no UI.

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Inline everything in SKILL.md** | Put arg parsing, jq calls, and mv logic in the skill body so Claude executes them step by step. | No new script file; matches smaller skills. | Not unit-testable with bats. Every test would need a live Claude session. Debugging becomes trial-and-error. | Rejected. |
| **B: Reuse `_common.sh::om_load_config`** | Source the shared config loader used by the hook scripts. | DRY; fewer code paths. | `om_load_config` exits 0 on any failure (missing config, missing jq, disabled flag) — that is correct for silent hooks but masks exactly the errors toggle must surface. Calling it would break AC5 (missing config error), AC4 (unknown-feature error), and the doctor cross-reference. | Rejected. Toggle reads the config directly, matching `vault-doctor.sh`'s stance for the same reason. |
| **C: In-place truncate (`> "$CONFIG"`)** | Write new JSON via `jq ... > "$CONFIG"`. | Simpler; one fewer step. | Breaks AC6 — shell redirection truncates the target *before* `jq` writes. A SIGKILL between truncate and write leaves the config empty. Fails the atomic-write contract. | Rejected. |
| **D: Write to temp file, then `mv`** | Render to `$CONFIG.tmp.$$`, then `mv` over the original. | Atomic on a single filesystem (POSIX guarantee); `jq` never touches the live config until success; EXIT trap cleans temp droppings. | One extra step. | **Selected.** |
| **E: `cp` + in-place edit** | `cp config.json config.json.bak`, edit, commit on success. | Keeps a visible backup the user can inspect. | Backup accumulates across runs or leaves stale files after crashes. Does not solve atomicity (the edit itself can still be partial). The user already has git + Obsidian Sync for history. | Rejected. |

---

## Security Considerations

- **Authentication**: None. Local CLI tool.
- **Authorization**: Writes only `~/.claude/obsidian-memory/config.json`. No path from user input is ever used as a filesystem target — the only configurable path comes from `$HOME`.
- **Input Validation**: All argv is validated against hard-coded whitelists (`rag`/`distill`, alias table). Unknown values fail with exit 2 *before* any jq call — no unsanitized input reaches a subprocess.
- **Data Sanitization**: `jq` quotes values safely by construction; the script never interpolates user strings into `jq` filter source. The filter is a fixed template (`.rag.enabled = $v` / `.distill.enabled = $v`) and the boolean is passed via `--argjson` so jq parses it as a JSON literal.
- **Sensitive Data**: Config contains no secrets.
- **Filesystem safety**: Temp file lives in the same directory as `$CONFIG` (required for `mv` atomicity on a single FS) and its name is deterministic (`$CONFIG.tmp.$$`) so an `EXIT` trap can always find and remove it.

---

## Performance Considerations

- **Caching**: None. One jq read + at most one jq write per invocation. The config is small (≤ 1 KB typical).
- **Pagination**: N/A.
- **Lazy Loading**: N/A.
- **Indexing**: N/A.

Expected wall time: single-digit ms for status, ~20–30 ms for a mutating run on a warm filesystem (bounded by two small `jq` invocations).

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Script (`vault-toggle.sh`) | bats integration (`tests/integration/toggle.bats`) | Every dispatch path: status, status-shorthand, explicit on, explicit off, flip from true, flip from false, already-in-state, unknown feature, unknown state alias, missing config, jq missing, atomic write survives SIGKILL simulation, key preservation with extra user keys, key preservation when the feature stanza is missing entirely. |
| Skill (`skills/toggle/SKILL.md`) | Gate sweep (`tests/integration/gate_sweep.bats` — already in place) | Frontmatter validity, description string triggers correctly, allowed-tools matches intent. Adding a new skill extends the existing sweep; no per-skill bats is needed for the Markdown. |
| BDD | cucumber-shell (`specs/feature-add-obsidian-memory-toggle-skill-for-rag-distill-enable-flags/feature.gherkin` + `tests/features/steps/toggle.sh`) | Every AC from `requirements.md`, with AC8 as a Scenario Outline over the alias table. |
| Static | `shellcheck scripts/vault-toggle.sh` | Exit 0. |

Tests run under the existing `tests/helpers/scratch.bash` harness: each scenario gets a scratch `$HOME` rooted at `$BATS_TEST_TMPDIR/home`, a fresh scratch config is written in the Given step, and assertions read the post-run config back from that scratch location. `assert_home_untouched` (already part of the harness) is called in teardown to prove the real `~/.claude/obsidian-memory/` was never mutated.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Atomic-write assumption fails on an exotic FS (e.g., fuse-mounted vault) | Low | Low — config lives under `~/.claude`, not the vault | Config path is under `$HOME/.claude/obsidian-memory/`, always on the same local FS as the temp file (which shares the directory). This is the same assumption every other script in the plugin makes. |
| `jq` version skew between macOS default (often < 1.6) and Linux CI | Low | Medium | Steering doc requires `jq ≥ 1.6`. `--argjson` is available from 1.5+. We probe jq presence and exit 1 with a brew hint if missing. |
| User runs toggle against a config with a missing feature stanza (e.g., older setup wrote only `rag`, never `distill`) | Medium | Low | `jq` treats `.distill.enabled` on a missing `distill` object as `null`. The read normalizes `null` → unset. The write uses `.distill.enabled = <bool>` which jq auto-creates the parent object. Unit test covers this. |
| SIGKILL between temp-file creation and `mv` leaves temp droppings | Low | Very low | `trap 'rm -f "$TMP" 2>/dev/null' EXIT` at script top. SIGKILL bypasses traps by definition, but the droppings are harmless and have a predictable `.tmp.$$` suffix — next successful run does not collide because `$$` is unique per PID. |
| "already in state" is ambiguous when the flag is unset (`null`) | Low | Low | Read normalizes unset → `true` (matches `_common.sh` semantics used by the hooks). Status prints the effective value, not the raw `null`. A `toggle rag on` against an unset-but-true-by-default flag writes it explicitly. AC7 covers the explicit-write case; an explicit scenario in BDD covers the unset case. |

---

## Open Questions

None. All behavioral edge cases are pinned in requirements; all implementation decisions are captured above.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #4 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Architecture follows existing project patterns (per `structure.md`) — mirrors `skills/doctor/` and `skills/teardown/`
- [x] All API/interface changes documented with schemas (CLI grammar, exit codes, stdout/stderr formats)
- [x] Database/storage changes planned with migrations (no schema change; key-preservation rules documented)
- [x] State management approach is clear (stateless one-shot)
- [x] UI components and hierarchy defined (N/A — CLI only)
- [x] Security considerations addressed
- [x] Performance impact analyzed
- [x] Testing strategy defined
- [x] Alternatives were considered and documented
- [x] Risks identified with mitigations
