# Design: Doctor Health-Check Skill

**Issues**: #2
**Date**: 2026-04-21
**Status**: Draft
**Author**: Rich Nunley

---

## Overview

The doctor skill is a read-only install-state reporter. The skill entry point is `skills/doctor/SKILL.md`, which instructs Claude to invoke a shell script (`scripts/vault-doctor.sh`) and relay its exit code and output. Putting the logic in a shell script — rather than in the SKILL's Markdown body — lets bats exercise every check deterministically without spawning the Claude CLI.

The script performs an ordered list of independent probes. Each probe is a pure function that inspects a path or a `PATH`-resolved binary and returns one of three states: `OK`, `FAIL` (with reason + hint), or `INFO` (informational only, never gates the exit code). Probes never short-circuit — doctor runs every check even if an earlier one failed, so the user sees the complete picture after a single invocation.

The script is the only new runtime artifact; all tests run against a scratch `$HOME` using the existing `tests/helpers/scratch.bash` harness (shipped with issue #1), so the integration tests can assert the read-only invariant via the `assert_home_untouched` helper already in place.

---

## Architecture

### Component Diagram

```
┌────────────────────────────────────────────────────────────┐
│  User invokes /obsidian-memory:doctor [--json]             │
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  skills/doctor/SKILL.md                                    │
│   - documents the command, flags, read-only guarantee      │
│   - instructs Claude to run scripts/vault-doctor.sh        │
│   - relays exit code + output verbatim                     │
└────────────────────────┬───────────────────────────────────┘
                         ▼
┌────────────────────────────────────────────────────────────┐
│  scripts/vault-doctor.sh                                   │
│   - parse args (--json)                                    │
│   - run each probe (see Data Flow)                         │
│   - format + emit report (human or JSON)                   │
│   - exit 0 if all probes are OK or INFO; exit 1 otherwise  │
└─────┬──────────────────────────────────────────────────────┘
      │
      ▼  READ ONLY (fs, env, PATH)
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│ $CONFIG JSON         │  │ $VAULT/claude-memory │  │ PATH binaries        │
│ (jq parse)           │  │ (stat / readlink)    │  │ (command -v)         │
└──────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

### Data Flow

```
1. SKILL.md receives invocation → shells out to scripts/vault-doctor.sh with any args.
2. vault-doctor.sh parses --json flag; decides output mode.
3. For each probe (ordered):
     P1 config_exists       → read $CONFIG file presence
     P2 vault_path_present  → jq `.vaultPath` from $CONFIG
     P3 vault_path_is_dir   → test -d on vaultPath
     P4 jq_on_path          → command -v jq  (Note: P1/P2 degrade gracefully when jq is missing)
     P5 claude_on_path      → command -v claude
     P6 sessions_dir        → test -d "<vault>/claude-memory/sessions"
     P7 projects_symlink    → test -L + readlink resolves to ~/.claude/projects
     P8 rag_enabled         → jq `.rag.enabled != false`
     P9 distill_enabled     → jq `.distill.enabled != false`
    I1 ripgrep_present      → command -v rg (INFO-only)
    I2 mcp_registered       → claude mcp list | grep -q obsidian  (INFO-only, best-effort)
4. Accumulate results in an associative map (key → {status, reason?, hint?}).
5. Format:
     - Human mode: one line per probe + final summary, colored on TTY.
     - JSON mode: jq-assembled object with an overall `ok` boolean.
6. Exit 0 if every probe is OK or INFO; exit 1 if any probe is FAIL.
```

---

## API / Interface Changes

### New Skill

| Skill | File | Invocation | Purpose |
|-------|------|------------|---------|
| `obsidian-memory:doctor` | `skills/doctor/SKILL.md` | `/obsidian-memory:doctor [--json]` | Read-only install-state report |

### New Script

| Script | File | Args | Exit code |
|--------|------|------|-----------|
| `vault-doctor.sh` | `scripts/vault-doctor.sh` | `[--json]` | `0` if every probe OK/INFO, `1` on any FAIL |

### Human-mode output format

```
obsidian-memory doctor
──────────────────────
OK    config         ~/.claude/obsidian-memory/config.json
OK    vault_path     /Users/x/Vault
OK    jq             /opt/homebrew/bin/jq (jq-1.7)
OK    claude         /Users/x/.local/bin/claude
OK    sessions_dir   /Users/x/Vault/claude-memory/sessions
OK    projects_symlink /Users/x/Vault/claude-memory/projects → /Users/x/.claude/projects
OK    rag_enabled    true
OK    distill_enabled true
INFO  ripgrep        /opt/homebrew/bin/rg
INFO  mcp            obsidian server registered

All checks passed.
```

Failure example:

```
obsidian-memory doctor
──────────────────────
OK    config         /Users/x/.claude/obsidian-memory/config.json
FAIL  vault_path     /tmp/nope does not exist — run /obsidian-memory:setup <vault>
OK    jq             /opt/homebrew/bin/jq
FAIL  claude         claude not on PATH — install the Claude Code CLI
…
2 check(s) failed.
```

### `--json` output schema

```json
{
  "ok": false,
  "checks": {
    "config":          { "status": "ok" },
    "vault_path":      { "status": "fail", "reason": "vault path /tmp/nope does not exist", "hint": "run /obsidian-memory:setup <vault>" },
    "jq":              { "status": "ok" },
    "claude":          { "status": "fail", "reason": "claude not on PATH", "hint": "install the Claude Code CLI" },
    "sessions_dir":    { "status": "ok" },
    "projects_symlink":{ "status": "ok" },
    "rag_enabled":     { "status": "ok" },
    "distill_enabled": { "status": "ok" },
    "ripgrep":         { "status": "info", "note": "vault-rag.sh will use POSIX fallback" },
    "mcp":             { "status": "info", "note": "obsidian MCP server not registered" }
  }
}
```

| Code / Type | Condition |
|-------------|-----------|
| Exit 0 | Every probe status ∈ {`ok`, `info`} |
| Exit 1 | ≥1 probe status is `fail` |

---

## Database / Storage Changes

None. Doctor is read-only and introduces no persistent state.

---

## State Management

No mutable state. Each probe produces a small record that is accumulated in a bash associative array within a single process. The process exits cleanly after emitting output.

---

## UI Components

Not applicable (no GUI). See the output format above for terminal "UI".

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Logic in SKILL.md, no script** | Let Claude orchestrate each check by calling `Bash` many times. | One file; no new script. | Not bats-testable without invoking Claude; every check becomes a separate permission prompt; slow. | Rejected — untestable and slow. |
| **B: Pure bash script, SKILL.md is a thin wrapper** | `scripts/vault-doctor.sh` does all the work; SKILL.md tells Claude to run it. | Bats-testable end to end; fast; single permission prompt. | Two files instead of one. | **Selected**. |
| **C: Node / Python implementation** | Richer JSON handling. | Better data structures. | Adds a runtime dep the plugin otherwise doesn't need; violates bash-first convention in `steering/tech.md`. | Rejected — stack mismatch. |
| **D: Short-circuit on first FAIL** | Exit at the first failing probe. | Slightly faster. | Users see only one problem at a time; forces re-runs. Doctor is already sub-second, so speed is a non-issue. | Rejected — UX regression. |
| **E: Reuse `scripts/_common.sh::om_load_config`** | Borrow the existing config loader. | DRY. | `om_load_config` calls `exit 0` on *any* failure — it's designed for hooks, not a reporter. Doctor needs to *observe* each failure, not mask it. | Rejected — different failure semantics. Doctor reads the config directly with its own probes. |

---

## Security Considerations

- [x] **Authentication**: None required. Doctor reads only user-owned files.
- [x] **Authorization**: The script reads only `~/.claude/obsidian-memory/config.json`, the configured `vaultPath` tree (top-level stat only), and `~/.claude/projects/` (via the symlink). No paths are accepted from the invocation environment beyond the optional `--json` flag.
- [x] **Input Validation**: The only argument is `--json`. Any other argv value is treated as unknown and the script exits 2 with a usage line. No shell interpolation of user input.
- [x] **Data Sanitization**: Output that includes paths from the config quotes them as plain text; no HTML, no shell echo expansion. ANSI escapes are emitted only when `stdout` is a TTY.
- [x] **Sensitive Data**: Config contains only a vault path and enable flags — no secrets. Doctor prints the vault path (already visible via `ls`).

---

## Performance Considerations

- [x] **Caching**: None needed. Each probe is O(1) in filesystem ops.
- [x] **Pagination**: N/A.
- [x] **Lazy Loading**: N/A.
- [x] **Indexing**: N/A.
- [x] **Wall time**: Target < 500 ms. Each probe is a `test`, `command -v`, or one `jq` invocation; worst case is ~10 fs/PATH probes plus two `jq` runs plus one optional `claude mcp list` (informational only and easy to skip if `claude` is missing).

---

## Testing Strategy

| Layer | Type | Coverage |
|-------|------|----------|
| Script internals | bats unit | Not needed — probes are short and tested through integration. |
| End-to-end | bats integration | `tests/integration/doctor.bats` with ≥1 test per failure mode, happy path, `--json`, and read-only invariant. |
| Specification | BDD (cucumber-shell) | `specs/feature-doctor-health-check-skill/feature.gherkin` — every AC has a scenario. Step definitions in `tests/features/steps/doctor.sh`. |
| Static | shellcheck | `scripts/vault-doctor.sh`, `tests/features/steps/doctor.sh`, any new `.bats`. |

Scratch harness contract (from `tests/helpers/scratch.bash`):

- `$HOME` is redirected to `$BATS_TEST_TMPDIR/home` for every test.
- `$VAULT` and `$PLUGIN_ROOT` are pre-exported.
- `assert_home_untouched` enforces the read-only invariant post-test by comparing a cksum digest of `~/.claude/obsidian-memory/`. Doctor tests call this in `teardown`.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| `jq` itself is missing, so probes P1/P2/P8/P9 cannot read the config | Medium | Medium | P4 (`jq_on_path`) runs before any jq-dependent probe result is finalized. If `jq` is missing, jq-dependent probes emit a degraded `SKIP` status that still prints as `FAIL: cannot check — jq missing`, so the user gets one actionable hint at the top of the report. |
| `claude mcp list` takes a long time or prompts | Low | Low | MCP probe is INFO-only and wrapped in a short `timeout 3`. If it errors or times out, it falls back to `INFO: mcp status unknown`. |
| `readlink -f` is not portable on macOS default bash (BSD readlink lacks `-f`) | High | Medium | Use POSIX `readlink` without `-f`; compare result to `$HOME/.claude/projects` directly. Already the pattern used in `scripts/_common.sh`. |
| Color codes leak into pipes | Low | Low | Gate every escape sequence on `[ -t 1 ]`. |
| Config contains an extra top-level key the probe doesn't expect | Low | Low | Probes use specific jq paths (`.vaultPath`, `.rag.enabled`, `.distill.enabled`) and default to safe values; unknown keys are ignored. |
| Existing `om_load_config` drifts from doctor's own field reads | Medium | Low | Doctor reads `.vaultPath` directly (same key as `_common.sh` uses today). If a future change renames the key, both paths must update in lockstep; that coupling is acknowledged and called out in the SKILL.md. |

---

## Open Questions

None remaining. Both requirements-level questions are resolved in-design (MCP status as `INFO`; `--json` includes per-check `hint`).

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #2 | 2026-04-21 | Initial feature spec |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Architecture follows existing project patterns (SKILL.md + `scripts/*.sh`, per `structure.md`)
- [x] All interface changes documented (SKILL.md invocation + script CLI + JSON schema)
- [x] No database/storage changes required (doctor is read-only)
- [x] No state management needed (single-process, no persistence)
- [x] UI output defined (human + JSON formats)
- [x] Security addressed (read-only, no untrusted interpolation)
- [x] Performance budgeted (< 500 ms wall time)
- [x] Testing strategy defined (bats + BDD + shellcheck)
- [x] Alternatives documented (5 options considered)
- [x] Risks identified with mitigations
