# Tasks: Detach `claude -p` in `vault-distill.sh` for async `/clear` distillation

**Issue**: #25
**Date**: 2026-04-22
**Status**: Planning
**Author**: Rich Nunley

---

## Summary

| Task | Description | Status |
|------|-------------|--------|
| T001 | Split `vault-distill.sh` into sync head + detached async worker | [ ] |
| T002 | Add regression test: hook returns fast, note lands asynchronously | [ ] |
| T003 | Update `/obsidian-memory:distill-session` skill to wait on worker | [ ] |
| T004 | Verify no regressions in existing distill tests | [ ] |

---

### T001: Split `vault-distill.sh` into Sync Head and Detached Async Worker

**File(s)**: `scripts/vault-distill.sh`
**Type**: Modify
**Depends**: None
**Acceptance**:
- [ ] Everything from the script's start through prompt rendering (current lines 1–101) remains in the main (synchronous) process and is unchanged behaviourally.
- [ ] A single function `_worker` contains the `claude -p` invocation, note assembly, file write (`$OUT_FILE`), and `Index.md` update — all the work currently on lines 103–165.
- [ ] `_worker` is invoked detached from the main hook process: stdin/stdout/stderr redirected to `/dev/null`, launched via `setsid -f` when available, falling back to `nohup … &` / `( … ) & disown` in that order.
- [ ] The synchronous head logs one line (`detached worker spawned; hook returning`) to `~/.claude/obsidian-memory/distill-debug.log` and then `exit 0`s.
- [ ] `_worker` logs: (a) start with its PID, (b) `claude -p exit=N`, (c) either `wrote $OUT_FILE (N bytes)` or `write to $OUT_FILE failed`, (d) `index updated; done` or the equivalent failure line — all with a `[worker pid=N]` prefix.
- [ ] `_worker` short-circuits (exits 0, logs a re-entrancy line) when it detects it is running inside a recursive `claude -p` context — the existing `CLAUDECODE=""` guard is preserved and extended with a second check against a new re-entrancy marker env var.
- [ ] No changes to the scope gate (`POLICY_DIR` / `SNAPSHOT` block), the size floor (2000 bytes), the slug derivation, or the frontmatter template.
- [ ] Every error path in the worker still ends in `exit 0` / `return 0` — the plugin must never surface a failure to the user.

**Notes**: Follow the fix strategy from `design.md`. Keep all existing `exit 0` and `2>/dev/null` silent-failure idioms — the plugin's contract with Claude Code is "a broken memory layer never blocks a session."

### T002: Add Regression Test (`@regression`)

**File(s)**: `tests/features/vault-distill-async.feature`, `tests/features/steps/distill.sh`, `tests/integration/vault-distill-async.bats`
**Type**: Create
**Depends**: T001
**Acceptance**:
- [ ] A new Gherkin feature file `tests/features/vault-distill-async.feature` is created, tagged `@regression`, with scenarios mapping to AC1, AC2, and AC3 from `requirements.md`.
- [ ] Step definitions extend `tests/features/steps/distill.sh` (or a sibling) with a "slow claude stub" helper that wraps the test's `claude` PATH shim in a `sleep 15 && echo …` script.
- [ ] A bats file `tests/integration/vault-distill-async.bats` exercises the same contract directly: pipes a synthetic `SessionEnd` payload (`reason: "clear"`) into `vault-distill.sh`, asserts `vault-distill.sh` returns within **2 seconds**, then polls the sessions dir for up to **20 seconds** and asserts the expected note appears.
- [ ] A second bats case stubs `claude` to return immediately and asserts exactly one note is written (guards against duplicate notes from recursive `claude -p` firing its own `SessionEnd`).
- [ ] A third bats case asserts the note is **not** written when the transcript is under 2 KB (proves the size-floor guard still runs synchronously and the worker is never spawned for trivial sessions).
- [ ] Tests fail if T001 is reverted — verified by checking out the pre-fix `vault-distill.sh` and running the new tests.

**Notes**: The `@regression` tag is required by `/verify-code`'s bug-fix verification contract. Keep the bats file focused on timing and cardinality — semantics (frontmatter, slug, template) are already covered by the existing `session-distillation-hook.bats`.

### T003: Update `/obsidian-memory:distill-session` Skill to Wait on Worker

**File(s)**: `skills/distill-session/SKILL.md`
**Type**: Modify
**Depends**: T001
**Acceptance**:
- [ ] After piping the synthetic payload into `vault-distill.sh`, the skill tails `~/.claude/obsidian-memory/distill-debug.log` (or polls the sessions dir) for up to **60 seconds** waiting for the worker's `wrote $OUT_FILE` line, then reports the file path as before.
- [ ] If the worker times out, the skill reports a clear "distillation still running in background" message and surfaces the tail of the debug log — it does **not** report "distillation returned no content" in that case.
- [ ] The skill's existing happy-path behaviour (finding the newest note and printing the first ~40 lines) is preserved when the worker completes within the timeout.

**Notes**: This is the AC3 consequence of T001 — the skill's "show me the note" UX now has to wait for the detached worker. Keep the wait bounded and non-blocking for the user.

### T004: Verify No Regressions in Existing Distill Tests

**File(s)**: `tests/integration/session-distillation-hook.bats`, `tests/integration/distill-session-skill.bats`, `tests/integration/vault-distill-scope.bats`, `tests/integration/gate_sweep.bats`
**Type**: Verify (no file changes)
**Depends**: T001, T002, T003
**Acceptance**:
- [ ] All existing bats suites pass under the new `vault-distill.sh` — in particular, the synchronous-path assertions in `session-distillation-hook.bats` still pass because the worker completes well within the test's existing wait window (the tests already use short `claude` stubs, so the worker finishes almost immediately).
- [ ] `distill-session-skill.bats` passes after the skill is updated in T003.
- [ ] `vault-distill-scope.bats` and `gate_sweep.bats` (scope-gate behaviour) pass unchanged — the scope gate runs in the sync head, so its semantics are identical.
- [ ] No new warnings or stderr noise appears in the bats run output beyond what's already present.

---

## Validation Checklist

Before moving to IMPLEMENT phase:

- [x] Tasks are focused on the fix — no feature work
- [x] Regression test is included (T002 tagged `@regression`)
- [x] Each task has verifiable acceptance criteria
- [x] No scope creep beyond the defect
- [x] File paths reference actual project structure (per `structure.md`: `scripts/`, `tests/integration/`, `tests/features/`, `skills/`)

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #25 | 2026-04-22 | Initial defect spec tasks — split sync head / async worker, regression test, skill wait-update. |
