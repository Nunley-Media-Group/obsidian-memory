# Root Cause Analysis: SessionEnd distill hook killed on `/clear`

**Issue**: #25
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley

---

## Root Cause

`vault-distill.sh` runs **synchronously** from the `SessionEnd` event — when the hook returns, Claude Code considers the hook complete. On a real session exit (`/exit` or the CLI closing), the parent process is actually terminating, and the harness keeps the pipeline alive long enough for `claude -p` (the slow step that produces the distilled summary) to return. On `/clear`, however, the session does **not** terminate — it resets context and continues. Claude Code treats `SessionEnd` hooks in that path as cleanup work that must yield quickly so the user can type their next prompt.

Instrumentation added on the investigation branch shows the `/clear` path consistently: `vault-distill.sh` is invoked, parses the payload, passes the scope gate, renders a ~38 KB prompt, logs `calling claude -p`, and is then killed before `claude -p` returns (within ~9 seconds of invocation, well before the typical 20–30 s needed for `claude -p` on a large transcript). No `claude -p exit=` line and no `wrote ...md` line are ever emitted for `REASON=clear` invocations. The file write, `Index.md` update, and link output all sit **downstream** of the blocking `claude -p` call, so when the harness kills the process, nothing lands in the vault.

A secondary, non-causal observation: the `claude -p` subprocess itself fires its own `SessionEnd` when it completes, which attempts to run `vault-distill.sh` recursively. That recursive invocation produces a cosmetic stderr line (`${CLAUDE_PLUGIN_ROOT}` is not expanded in the headless subprocess's plugin-hook context) but is not the root cause — the primary hook is already dead by then on the `/clear` path.

### Affected Code

| File | Lines | Role |
|------|-------|------|
| `scripts/vault-distill.sh` | 103 | Synchronous `NOTE_BODY="$(CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null)"` — the blocking call that exceeds the `/clear` grace period |
| `scripts/vault-distill.sh` | 105–141 | Note assembly (`printf` block), file write to `$OUT_FILE`, and `Index.md` update — all downstream of the blocking call, so none of them execute when the hook is killed |
| `scripts/vault-distill.sh` | 1–101 | Unchanged setup (config load, payload parse, scope gate, size floor, slug + paths, prompt render) — this runs fast and finishes before the hook is killed |
| `hooks/hooks.json` | 23–32 | `SessionEnd` registration — unchanged |

### Triggering Conditions

- `SessionEnd` fires with `reason: "clear"` (Claude Code's canonical reason for the `/clear` command).
- The scope gate passes (default `projects.mode: all`, or the project is allowlisted).
- The transcript is ≥ 2 KB (the trivial-session floor — any non-throwaway session).
- `claude -p` takes long enough to exceed the `/clear` `SessionEnd` grace period (typically true once the transcript plus rendered prompt exceeds ~5–10 KB, which happens within a handful of exchanges).

None of these were caught before because the integration tests exercise the synchronous path only — they pipe a payload into `vault-distill.sh` from `bats` and wait for it to finish, which masks the harness-timeout behaviour that only manifests on `/clear`.

---

## Fix Strategy

### Approach

Split `vault-distill.sh` into two clean phases: (1) a **synchronous head** that runs everything up to and including prompt rendering (cheap, O(100 ms)), and (2) an **asynchronous worker** that runs the `claude -p` call, note assembly, file write, and `Index.md` update. The synchronous head spawns the worker as a detached background process (via `setsid` + redirected std streams + `disown`), logs that the worker was spawned, and `exit 0`s — returning to the harness well inside any plausible `/clear` grace budget. The worker runs independently of Claude Code's process tree and writes the note after the hook has already returned.

This matches the project's existing "never block the user" principle (stated in `steering/tech.md`) and is the minimal change that satisfies FR1. No refactoring of the prompt rendering, scope gate, or template layer is required — the synchronous head keeps their current shape and semantics.

### Changes

| File | Change | Rationale |
|------|--------|-----------|
| `scripts/vault-distill.sh` | Extract the `claude -p` call, note assembly, file write, and `Index.md` update into a single shell function (the "worker"). Replace the inline synchronous invocation with a detached launch: redirect the worker's stdin/stdout/stderr to `/dev/null`, run it under `setsid` (POSIX `setsid` on Linux/macOS; when unavailable, fall back to `( … ) & disown`), and have the synchronous head return `exit 0` immediately after the spawn. | Satisfies FR1 — hook returns before the `/clear` grace budget elapses. The worker survives the parent tearing down because it's in a new session/process group with no controlling terminal. |
| `scripts/vault-distill.sh` | Add structured debug-log lines at worker start, `claude -p` exit, file-write outcome, and index-update outcome (gated by an already-written or newly-added `OM_DEBUG_LOG` path under `~/.claude/obsidian-memory/`). Use a `[worker pid=N]` prefix so worker output is distinguishable from the synchronous head. | Satisfies FR2 — future `/clear` failures are diagnosable without re-instrumentation. |
| `scripts/vault-distill.sh` | Inside the worker, guard against firing twice by re-entrancy: the worker no-ops when `CLAUDECODE` env suggests it was spawned by a recursive `claude -p` subprocess (same guard pattern as the existing `CLAUDECODE=""` suppression on line 103). | Satisfies FR3 — exactly one note per `SessionEnd`, even when the recursive `claude -p` subprocess's own hook fires. |
| `tests/integration/session-distillation-hook.bats` *(existing)* | Add a BATS case that stubs `claude -p` with a sleep-then-echo script and asserts: (a) `vault-distill.sh` returns within 2 seconds; (b) the expected note file eventually materialises under the sessions dir. | Locks in AC1's timing contract under CI and exercises the worker path the old tests missed. |

### Blast Radius

- **Direct impact**: `scripts/vault-distill.sh` only. No changes to `_common.sh`, `hooks.json`, scope gates, config schema, or any other hook.
- **Indirect impact**:
  - Manual `/obsidian-memory:distill-session` skill shells into `vault-distill.sh` with a synthetic payload (`skills/distill-session/SKILL.md`). After the fix, the skill's foreground call will return immediately while the worker completes in the background. The skill currently finds and prints the "newest note" after the hook returns, which will now race with the detached worker. This is an acceptance-criteria surface (AC3) and is addressed by the skill tailing the debug log or waiting on the worker's PID.
  - `vault-doctor.sh` is read-only and unaffected.
  - Scope-gate snapshots (`~/.claude/obsidian-memory/session-policy/`) are consumed in the synchronous head, not the worker — unchanged semantics.
- **Risk level**: Low. The change is confined to one file, uses standard POSIX backgrounding primitives, and preserves the existing guarantee that a broken memory layer never blocks a session (failures in the worker are logged but never surfaced).

---

## Regression Risk

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| The detached worker is killed when the parent Claude process exits abruptly (SIGKILL on the whole group), losing the note | Low | `setsid` places the worker in its own session; `disown` detaches it from the shell's job table. Verified on macOS Darwin + Linux. A SIGKILL to the whole process group would also kill every other detached child of the harness — that's a pre-existing OS-level risk not introduced by this fix. |
| Duplicate notes written when the recursive `claude -p` subprocess's own `SessionEnd` hook fires and re-enters `vault-distill.sh` | Medium | The worker guards with the existing `CLAUDECODE=""` pattern: the recursive invocation comes in with `CLAUDECODE` unset (because we cleared it), and the worker short-circuits when it detects a recursive entry. AC3 and a new BATS case lock this in. |
| The manual `distill-session` skill returns before the note is written, breaking its "show me the note" UX | Medium | Update the skill to tail `distill-debug.log` for the worker's `wrote $OUT_FILE` line, or `wait` on the worker's recorded PID with a 60 s timeout. AC3 exercises this path. |
| Race between the worker and a subsequent `/clear` spawning another worker, corrupting `Index.md` | Low | `Index.md` update already uses a `mktemp + mv` atomic-replace pattern; concurrent workers will serialize on the filesystem. Worst case: one of the two link-line inserts wins; neither file is corrupted. |
| `setsid` is unavailable on exotic shells or minimal Alpine containers | Low | Fallback chain: prefer `setsid -f`, then `nohup … &`, then bare `( … ) & disown`. All three detach the worker enough to survive normal hook teardown; only the first fully survives SIGHUP from a controlling terminal. |
| Debug log grows unbounded | Low | The logging lines are short (~100 B each) and fire at most 4× per session. At one session per hour, the log grows ~10 KB/day — acceptable. A cap or rotation can be added as a later housekeeping task if warranted. |

---

## Alternatives Considered

| Option | Description | Why Not Selected |
|--------|-------------|------------------|
| Raise the `SessionEnd` hook timeout in the user's `settings.json` | Ask users to set `hooks.SessionEnd.timeout` to a larger value | Requires a per-user settings change, doesn't fix the root cause (the harness still blocks context reset on the hook), and won't help users who don't know about the setting. Out of scope per the issue. |
| Skip distillation when `REASON=clear` | Short-circuit the hook and rely only on `/exit` and the manual skill for persistence | Defeats the point — `/clear` is the *most common* way users reset context in long sessions, so skipping it means most sessions are never distilled. Would effectively revert the plugin's core value proposition. |
| Pre-compute the summary eagerly on every prompt and persist on `SessionEnd` | Run a rolling summary in `UserPromptSubmit` or a periodic timer | Hugely more invasive, adds per-prompt latency, and duplicates work already handled by `claude -p`. Not justified by a single harness-timing issue. |
| Use `SessionStart` on the next session to distill the previous transcript | Detect the previous session's transcript file at new-session boot and distill it | Complicates the state model (which transcript is "previous"? what if the user switches projects?), and still has to run `claude -p` — it just relocates the synchronous block to a different hook that has its own timing constraints. The async-worker fix is simpler and more targeted. |

---

## Validation Checklist

Before moving to TASKS phase:

- [x] Root cause is identified with specific code references (`scripts/vault-distill.sh:103`)
- [x] Fix is minimal — one file changed, one behavioural split
- [x] Blast radius is assessed (confined to `vault-distill.sh`; manual skill touch-up is an AC3 consequence)
- [x] Regression risks are documented with mitigations
- [x] Fix follows existing project patterns (POSIX shell, `exit 0` on every error path, debug log under `~/.claude/obsidian-memory/`)

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #25 | 2026-04-22 | Initial defect spec: detach `claude -p` into an async worker so `/clear` grace period doesn't kill the hook. |
