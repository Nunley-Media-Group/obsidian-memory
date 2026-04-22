# Design: Teardown Skill

**Issues**: #3
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## Overview

The teardown skill is the inverse of `/obsidian-memory:setup`. Its entry point is `skills/teardown/SKILL.md`, which instructs Claude to invoke a shell script (`scripts/vault-teardown.sh`) and relay its exit code and output. Putting the logic in a shell script — rather than in the SKILL's Markdown body — matches the doctor pattern (`feature-doctor-health-check-skill/`) and lets bats exercise every branch deterministically without spawning the Claude CLI.

The script follows a strict three-stage sequence: **discover** (read config, resolve vault path), **validate** (path-safety gate against the setup layout), **act** (remove config + symlink by default; optionally remove sessions/Index.md after typed `yes`; optionally unregister the MCP server). The validation gate runs before any deletion, and every deletion path gates on it — there is no code path that removes anything before validation passes. This ordering is the single load-bearing safety property of the feature.

The script is the only new runtime artifact. All tests run against a scratch `$HOME` using the existing `tests/helpers/scratch.bash` harness (shipped with issue #1). Integration tests can assert the destructive boundary by comparing mtime/cksum digests of `sessions/` and `Index.md` across every scenario — in every path that is not `--purge --yes`, those digests must be unchanged.

---

## Architecture

### Component Diagram

```
┌────────────────────────────────────────────────────────────┐
│  User invokes /obsidian-memory:teardown [--purge]          │
│                                         [--unregister-mcp] │
│                                         [--dry-run]        │
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  skills/teardown/SKILL.md                                  │
│   - documents the command, flags, safety guarantees        │
│   - instructs Claude to run scripts/vault-teardown.sh      │
│   - relays exit code + output verbatim                     │
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  scripts/vault-teardown.sh                                 │
│   Stage 1: discover    → read $CONFIG, parse vaultPath     │
│   Stage 2: validate    → path-safety gate on <vault>/      │
│                            claude-memory/ layout           │
│   Stage 3: plan        → enumerate removals + preservals   │
│   Stage 3a (--dry-run) → print plan, exit 0                │
│   Stage 3b (--purge)   → prompt for typed "yes"            │
│   Stage 4: act         → unlink + rm in a fixed order      │
│   Stage 5: --unregister-mcp (best-effort, non-fatal)       │
│   Stage 6: summary + exit                                  │
└─────┬──────────────────────────────────────────────────────┘
      │
      ▼ WRITES ONLY UNDER ~/.claude/obsidian-memory/ AND <vault>/claude-memory/
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│ $CONFIG JSON         │  │ $VAULT/claude-memory │  │ claude mcp remove    │
│ (rm on ACT)          │  │ (unlink + rm -r)     │  │ (on --unregister-mcp)│
└──────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

### Data Flow

```
1. SKILL.md receives invocation → shells out to scripts/vault-teardown.sh with $ARGS.
2. vault-teardown.sh parses flags (--purge, --unregister-mcp, --dry-run).
3. Stage 1 — discover:
     - If $CONFIG is not present → print "no obsidian-memory config found — nothing to do", exit 0.
     - Else jq-parse .vaultPath; empty/null vaultPath → path-safety FAIL with hint.
4. Stage 2 — validate (path-safety gate):
     V1  <vault> exists and is a directory
     V2  <vault>/claude-memory/ exists and is a directory
     V3  <vault>/claude-memory/projects is either (a) a symlink resolving to $HOME/.claude/projects
         (exact match after readlink, no -f), or (b) absent
         → anything else (regular file, directory, symlink pointing elsewhere) = FAIL
     V4  jq is available (needed for discover, but re-checked here as a defensive gate)
     If any validator fails → print detected vault path + specific mismatch +
                               "run /obsidian-memory:doctor to diagnose" hint, exit 1.
5. Stage 3 — plan:
     PLAN_REMOVE = [ $CONFIG, <vault>/claude-memory/projects (if symlink exists) ]
     PLAN_PRESERVE = [ <vault>/claude-memory/sessions/, <vault>/claude-memory/Index.md ]
     If --purge:
       PLAN_REMOVE += <vault>/claude-memory/sessions/, <vault>/claude-memory/Index.md
       PLAN_PRESERVE = []
     If --unregister-mcp:
       PLAN_REMOVE += "obsidian MCP server registration (via claude mcp remove)"
6. Stage 3a — if --dry-run:
     Print the plan with "WOULD REMOVE:" / "WOULD PRESERVE:" labels. Exit 0.
7. Stage 3b — if --purge (and not --dry-run):
     Print a count + the absolute paths that would be deleted.
     Prompt: "Type 'yes' to delete these notes (anything else cancels): "
     Read one line from stdin. EOF or any response != "yes" (case-sensitive exact) →
       drop sessions/Index.md from PLAN_REMOVE, add them back to PLAN_PRESERVE,
       print "sessions preserved — purge cancelled".
8. Stage 4 — act (fixed order, every unlink/rm is guarded by absolute-path + path-safety pre-check):
     a. unlink <vault>/claude-memory/projects  (if present)
     b. if --purge confirmed:
          rm -rf <vault>/claude-memory/sessions
          rm -f  <vault>/claude-memory/Index.md
          rmdir <vault>/claude-memory  (only if empty; swallow failure)
     c. rm -f $CONFIG
     d. rmdir ~/.claude/obsidian-memory  (only if empty; swallow failure)
9. Stage 5 — if --unregister-mcp:
     Run `timeout 3 claude mcp remove obsidian -s user` (or the current equivalent).
     Non-zero exit → print one-line non-fatal warning, continue.
10. Stage 6 — summary + exit 0 (success paths) or exit 1 (validation refusal) or exit 2 (bad args).
```

---

## API / Interface Changes

### New Skill

| Skill | File | Invocation | Purpose |
|-------|------|------------|---------|
| `obsidian-memory:teardown` | `skills/teardown/SKILL.md` | `/obsidian-memory:teardown [--purge] [--unregister-mcp] [--dry-run]` | Inverse of setup — removes config + symlink, optionally purges distilled notes, optionally unregisters MCP |

### New Script

| Script | File | Args | Exit code |
|--------|------|------|-----------|
| `vault-teardown.sh` | `scripts/vault-teardown.sh` | `[--purge] [--unregister-mcp] [--dry-run]` | `0` on success (including idempotent + cancelled purge), `1` on path-safety refusal, `2` on bad usage |

### Flag semantics

| Flag combination | Behavior |
|------------------|----------|
| *(none)* | Remove config + symlink; preserve sessions + Index.md; do not touch MCP |
| `--purge` | Default removals, plus sessions + Index.md after typed `yes` |
| `--unregister-mcp` | Default removals, plus best-effort `claude mcp remove` |
| `--purge --unregister-mcp` | Both of the above |
| `--dry-run` | Print the plan; touch nothing; no MCP call; no prompt; exit 0 |
| `--dry-run --purge` | Plan includes sessions+Index.md under WOULD REMOVE; still no prompt, still no deletion |
| Any unknown flag | Exit 2 with a usage line |

### Human-mode output format

Default teardown, healthy install:

```
obsidian-memory teardown
────────────────────────
vault: /Users/x/Vault

PLAN
  REMOVE     ~/.claude/obsidian-memory/config.json
  REMOVE     /Users/x/Vault/claude-memory/projects (symlink)
  PRESERVE   /Users/x/Vault/claude-memory/sessions/  (12 notes)
  PRESERVE   /Users/x/Vault/claude-memory/Index.md

ACTIONS
  REMOVED    /Users/x/Vault/claude-memory/projects
  REMOVED    /Users/x/.claude/obsidian-memory/config.json

Teardown complete. Distilled notes preserved.
```

Purge with confirmation:

```
obsidian-memory teardown --purge
────────────────────────────────
vault: /Users/x/Vault

PLAN
  REMOVE     ~/.claude/obsidian-memory/config.json
  REMOVE     /Users/x/Vault/claude-memory/projects (symlink)
  REMOVE     /Users/x/Vault/claude-memory/sessions/  (12 notes)
  REMOVE     /Users/x/Vault/claude-memory/Index.md

About to delete 12 distilled note file(s) under /Users/x/Vault/claude-memory/sessions/.
Type 'yes' to confirm (anything else cancels): yes

ACTIONS
  REMOVED    /Users/x/Vault/claude-memory/projects
  REMOVED    /Users/x/Vault/claude-memory/sessions/  (12 notes)
  REMOVED    /Users/x/Vault/claude-memory/Index.md
  REMOVED    /Users/x/.claude/obsidian-memory/config.json

Teardown complete. Distilled notes deleted.
```

Purge cancelled:

```
...
Type 'yes' to confirm (anything else cancels): y

Sessions preserved — purge cancelled.

ACTIONS
  REMOVED    /Users/x/Vault/claude-memory/projects
  PRESERVED  /Users/x/Vault/claude-memory/sessions/
  PRESERVED  /Users/x/Vault/claude-memory/Index.md
  REMOVED    /Users/x/.claude/obsidian-memory/config.json

Teardown complete. Distilled notes preserved.
```

Path-safety refusal:

```
obsidian-memory teardown
────────────────────────
vault: /tmp/unrelated-dir

REFUSED
  /tmp/unrelated-dir does not contain a claude-memory/ directory.
  This does not look like an obsidian-memory install — refusing to delete anything.
  Run /obsidian-memory:doctor to diagnose the config, then reconcile manually.
```

Idempotent (nothing to do):

```
obsidian-memory teardown
────────────────────────
No obsidian-memory config found at ~/.claude/obsidian-memory/config.json — nothing to do.
```

### Exit code contract

| Exit code | Condition |
|-----------|-----------|
| `0` | Successful teardown (any flag combination), cancelled purge, idempotent no-op, dry-run |
| `1` | Path-safety refusal (AC4) |
| `2` | Bad usage (unknown flag) |

---

## Database / Storage Changes

None. Teardown is a destructive inverse of setup's filesystem footprint; it introduces no new persistent state.

---

## State Management

No mutable state beyond local bash variables within a single process. The plan/act split is implemented in-process as two small arrays (`PLAN_REMOVE`, `PLAN_PRESERVE`) populated in Stage 3 and consumed in Stage 4.

---

## UI Components

Not applicable (no GUI). See the output formats above for terminal "UI".

### Confirmation prompt

| Aspect | Specification |
|--------|---------------|
| Prompt text | `Type 'yes' to confirm (anything else cancels): ` |
| Input source | stdin, single line via `read -r REPLY` |
| Accept condition | `[ "$REPLY" = "yes" ]` — case-sensitive exact match on literal `yes` |
| Reject conditions | Any other string, empty line, EOF, SIGINT |
| Timeout | None — the prompt blocks until the user responds (EOF is a clean "no") |
| TTY requirement | Not enforced — the prompt writes to stderr and reads from stdin, so a non-interactive invocation simply hits EOF immediately and cancels the purge, which is the correct failsafe behavior |

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Logic in SKILL.md, no script** | Let Claude orchestrate each check by calling `Bash` many times. | One file; no new script. | Not bats-testable without invoking Claude; every deletion would need its own permission prompt; slow. | Rejected — untestable and slow. |
| **B: Pure bash script, SKILL.md is a thin wrapper** | `scripts/vault-teardown.sh` does all the work; SKILL.md tells Claude to run it. | Bats-testable end to end; fast; single permission prompt; matches doctor pattern. | Two files instead of one. | **Selected**. |
| **C: Default `--purge` ON; require `--no-purge` to preserve** | Mirror the "delete by default, flag to keep" pattern common in package managers. | Fewer flags to learn. | Distilled notes are the user's memory. The default must be the safe choice. | Rejected — violates the core safety principle in the issue and `steering/product.md`. |
| **D: `-y/--yes` flag to skip typed-`yes` confirmation** | Let CI / automation suppress the prompt. | Scriptability. | The confirmation is the load-bearing guarantee that distilled notes are not accidentally deleted. An override flag eliminates it. | Rejected — no override. Anyone who truly wants unattended purge can `rm -rf` the sessions directory directly (they are plain Markdown). |
| **E: Reuse `scripts/_common.sh::om_load_config`** | Borrow the existing config loader. | DRY. | `om_load_config` exits 0 on any failure (designed for hooks); teardown needs to *observe* a missing config and handle it differently from a mismatched layout. | Rejected — different failure semantics. Teardown reads the config directly with its own jq call, same as doctor does. |
| **F: Tri-state path-safety (STRICT, LENIENT, OFF)** | Let the user relax the path-safety gate with a flag. | Flexibility for weird layouts. | Undermines the single load-bearing safety property. | Rejected — the mismatched-footprint path is always a refusal; the user is told to reconcile manually. |

---

## Security Considerations

- [x] **Authentication**: None required. Teardown operates on user-owned files.
- [x] **Authorization**: The script writes only under `~/.claude/obsidian-memory/` and `<vault>/claude-memory/`. The vault path comes exclusively from `config.json` (jq-parsed); no path is accepted from invocation flags. Any attempted write outside these subtrees would have to come from a `vaultPath` in the config that is validated by Stage 2 — and the path-safety gate refuses every layout that does not match setup's footprint.
- [x] **Input Validation**: The only arguments are three named flags (`--purge`, `--unregister-mcp`, `--dry-run`). Any other argv value prints a usage line and exits 2. No shell interpolation of user input. The stdin confirmation is compared with `[ "$REPLY" = "yes" ]`, not evaluated or interpolated.
- [x] **Data Sanitization**: Output that includes paths from the config is printed as plain text; no HTML, no shell echo expansion. ANSI escapes are emitted only when `stdout` is a TTY.
- [x] **Sensitive Data**: Config contains only a vault path and enable flags — no secrets. Teardown does not log the config contents; it only reports paths that are already visible via `ls`.
- [x] **Destructive safety** (new, specific to this skill): Every `rm` / `unlink` invocation uses an absolute path computed from the validated vault path. No `rm -rf $var` without absolute-path + path-safety pre-check. No variable expansion in an `rm` target that could be unset. The sessions and Index.md removals happen only after the typed-`yes` gate. The path-safety refusal exits before any deletion runs.

---

## Performance Considerations

- [x] **Caching**: None needed. Each action is O(1) in filesystem ops.
- [x] **Pagination**: N/A.
- [x] **Lazy Loading**: N/A.
- [x] **Indexing**: N/A.
- [x] **Wall time**: Target < 500 ms in the common case. The `--unregister-mcp` path can add wall time bounded by `timeout 3`.
- [x] **Large sessions directories**: `--purge` runs `rm -rf` on a directory that may contain thousands of files. This is not a hot path and is bounded by the filesystem's delete throughput. No progress indicator is needed — teardown is a deliberate one-shot user action.

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Script internals | bats unit | Not needed — stages are short and tested through integration. |
| End-to-end | bats integration | `tests/integration/teardown.bats` with ≥1 test per AC plus parameterized tests for the typed-`yes` variants. |
| Specification | BDD (cucumber-shell) | `specs/feature-add-obsidian-memory-teardown-skill/feature.gherkin` — every AC has a scenario. Step definitions in `tests/features/steps/teardown.sh`. |
| Static | shellcheck | `scripts/vault-teardown.sh`, `tests/features/steps/teardown.sh`, any new `.bats`. |

Scratch harness contract (reused from `tests/helpers/scratch.bash`):

- `$HOME` is redirected to `$BATS_TEST_TMPDIR/home` for every test.
- `$VAULT` and `$PLUGIN_ROOT` are pre-exported.
- `assert_home_untouched` enforces that non-teardown-scoped paths under `$HOME` are unchanged (but teardown *does* modify `~/.claude/obsidian-memory/`, so tests will assert its specific pre/post state manually instead of calling the generic helper).
- **New helper proposed**: `assert_sessions_untouched` — cksum digest of `$VAULT/claude-memory/sessions/` and `$VAULT/claude-memory/Index.md` taken in `setup()`, compared in `teardown()`. Every AC except AC2's `yes` branch asserts this helper. Lives at `tests/helpers/scratch.bash` alongside the existing `assert_home_untouched`.

### Test matrix (minimum)

| Test | Scenario |
|------|----------|
| happy_default | AC1 — healthy install, default flags |
| purge_yes | AC2 — `--purge` with literal `yes` on stdin |
| purge_y | AC2 — `--purge` with `y` on stdin (must cancel) |
| purge_cap_YES | AC2 — `--purge` with `YES` (must cancel) |
| purge_empty | AC2 — `--purge` with empty line (must cancel) |
| purge_eof | AC2 — `--purge` with `</dev/null` (must cancel) |
| unregister_mcp_ok | AC3 — `--unregister-mcp` with stub `claude` succeeding |
| unregister_mcp_fail | AC3 — `--unregister-mcp` with stub `claude` returning non-zero (non-fatal) |
| refuse_no_claude_memory | AC4 — vaultPath points at a dir without `claude-memory/` |
| refuse_projects_not_symlink | AC4 — `<vault>/claude-memory/projects` is a regular directory |
| refuse_projects_wrong_target | AC4 — symlink pointing somewhere other than `~/.claude/projects` |
| refuse_vault_missing | AC4 — vaultPath points at a non-existent directory |
| idempotent_no_config | AC5 — no config at all |
| idempotent_after_default | AC5 — run default teardown, then run teardown again |
| dry_run_healthy | AC6 — `--dry-run` on a healthy install, nothing mutates |
| dry_run_purge | AC6 — `--dry-run --purge` prints sessions in WOULD REMOVE but does not prompt, does not delete |
| dry_run_unregister | AC6 — `--dry-run --unregister-mcp` does not invoke `claude mcp remove` |

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| An edited `config.json` points at an unrelated directory and teardown deletes user files | Low | **Critical** | Path-safety gate (Stage 2 / AC4) refuses every layout that does not look like setup's footprint. No `rm` runs before validation passes. Unit-tested in `refuse_*` tests. |
| User types `y` expecting it to confirm and the sessions get deleted | Low | **Critical** | Typed-`yes` gate is case-sensitive exact match on literal `yes`. `y`, `Y`, `YES` all cancel the purge. Tested via parameterized scenarios. |
| Non-interactive invocation (e.g., piped from a script) makes the prompt silently skip to EOF and deletes sessions | High without mitigation | **Critical** | EOF on stdin is treated as refusal. A non-interactive `--purge` cancels the purge — this is the correct failsafe and matches the spirit of the typed-`yes` rule. |
| `readlink -f` is not portable on macOS default bash (BSD readlink lacks `-f`) | High | Medium | Use POSIX `readlink` without `-f`; compare result to `$HOME/.claude/projects` directly. Already the pattern used in `scripts/_common.sh` and `scripts/vault-doctor.sh`. |
| `rmdir` on `<vault>/claude-memory/` fails because of hidden files | Medium | Low | Swallow the failure (`rmdir ... 2>/dev/null || true`). Leaving the directory is acceptable — it is not part of the core "removed" contract, just a cosmetic cleanup after a successful purge. |
| `claude mcp remove` prompts or takes a long time | Low | Low | Wrap in `timeout 3`. Non-zero/timeout → single-line non-fatal warning. Mirrors doctor's MCP probe. |
| Color codes leak into pipes | Low | Low | Gate every escape sequence on `[ -t 1 ]`. |
| User runs teardown mid-session and a new distillation lands after the scan | Low | Low | Out of scope. Teardown is a one-shot deliberate action; concurrent writes are the user's responsibility. The `--purge` count displayed in the prompt is a snapshot, not a lock. |
| `jq` is missing so we cannot read `vaultPath` | Medium | Medium | Stage 2 (V4) returns a path-safety refusal with a hint to install `jq`. Teardown exits 1 without deleting anything, same as the other refusal paths. |
| A future change to setup's layout (e.g., a new artifact) is not reflected in teardown | Medium | Medium | Keep teardown's `PLAN_REMOVE` / `PLAN_PRESERVE` lists next to setup's documented layout in the SKILL.md so the coupling is visible. `/write-spec` amendments against `feature-vault-setup/` should call out teardown impact in Change History. |

---

## Open Questions

None remaining. Each of the three requirements-level questions is resolved above:

- Confirmation prompt is case-sensitive literal `yes` (Alternatives Considered Option D, Risks row 2).
- `--dry-run` suppresses every side effect including MCP (Flag semantics table).
- `rmdir <vault>/claude-memory/` is best-effort only (Risks row 5).

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #3 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Architecture follows existing project patterns (SKILL.md + `scripts/*.sh`, per `structure.md`; mirrors doctor's shape)
- [x] All interface changes documented (SKILL.md invocation + script CLI + exit code contract)
- [x] No database/storage changes required (teardown is a filesystem inverse)
- [x] No state management needed (single-process, no persistence)
- [x] UI output defined (default, purge, cancelled-purge, refusal, idempotent formats)
- [x] Security addressed (path-safety gate, absolute-path-only deletions, typed-`yes` gate)
- [x] Performance budgeted (< 500 ms common case; `timeout 3` on MCP)
- [x] Testing strategy defined (bats + BDD + shellcheck; explicit test matrix)
- [x] Alternatives documented (6 options considered, including tri-state path-safety and `-y` override)
- [x] Risks identified with mitigations (destructive-safety risks called out specifically)
