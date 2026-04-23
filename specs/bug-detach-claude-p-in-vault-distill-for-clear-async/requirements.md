# Defect Report: SessionEnd distill hook killed on `/clear`

**Issue**: #25
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley
**Severity**: High
**Related Spec**: `specs/feature-session-distillation-hook/`

---

## Reproduction

### Steps to Reproduce

1. Start a Claude Code session in a project where `obsidian-memory` is installed and `distill.enabled: true`.
2. Hold a conversation that produces a transcript ≥ 2 KB (the hook's trivial-session floor).
3. Run `/clear` to reset the context (Claude Code fires `SessionEnd` with `reason: "clear"`).
4. Wait 60 seconds and inspect `<vault>/claude-memory/sessions/<slug>/`.

### Environment

| Factor | Value |
|--------|-------|
| **OS / Platform** | macOS Darwin 25.3.0 |
| **Version / Commit** | `obsidian-memory` 0.5.0 |
| **Runtime** | Claude Code CLI 2.1.118 |
| **Configuration** | `distill.enabled: true`, `projects.mode: all` |

### Frequency

Always — every `/clear` on a session with a transcript large enough to make `claude -p` slow (which is the normal case once a session has accumulated any real activity).

---

## Expected vs Actual

| | Description |
|---|-------------|
| **Expected** | Within ~60 seconds of `/clear`, a new distillation note appears in `<vault>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` and is linked from `Index.md`. |
| **Actual** | No note is written. `Index.md` is unchanged. The vault is silent after `/clear`. |

### Error Output

From an instrumented `vault-distill.sh` (debug log at `~/.claude/obsidian-memory/distill-debug.log`):

```
[03:10:07Z] === vault-distill.sh invoked (pid=60130, CLAUDECODE=<unset>)
[03:10:07Z] parsed: REASON=clear
[03:10:07Z] scope gate: passed (state=live)
[03:10:07Z] transcript size=300007
[03:10:08Z] prompt bytes=38584; calling claude -p
          ← process killed here; no further log lines
```

No `claude -p exit=` or `wrote ...md` line is logged. By contrast, the `/exit` path produces the full `claude -p exit=0 ... wrote <file>` trace and writes the note.

---

## Acceptance Criteria

### AC1: `/clear` Triggers a Distillation Note

**Given** a Claude Code session with an enabled `distill` hook and a transcript of at least 2 KB  
**When** the user runs `/clear`  
**Then** a distillation note appears in `<vault>/claude-memory/sessions/<slug>/YYYY-MM-DD-HHMMSS.md` within 60 seconds of the `/clear`  
**And** the note is linked from `<vault>/claude-memory/Index.md`

### AC2: Normal Exit Path Is Not Regressed

**Given** a Claude Code session with an enabled `distill` hook and a transcript of at least 2 KB  
**When** the user ends the session via `/exit` (or closes the CLI)  
**Then** a distillation note is written to the vault exactly as it was before the fix (no missing note, no duplicate note)

### AC3: Manual `distill-session` Skill Is Unaffected

**Given** the user invokes `/obsidian-memory:distill-session` with the newest transcript  
**When** the skill pipes a synthetic `SessionEnd`-shaped payload into `vault-distill.sh`  
**Then** exactly one distillation note is written and linked in `Index.md`, matching the behaviour documented in `specs/feature-manual-distill-skill/requirements.md`

---

## Functional Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| FR1 | `vault-distill.sh` must return `exit 0` from its main process before the Claude Code `SessionEnd` grace period elapses on `/clear`, so the harness does not kill the hook mid-flight. The slow work (`claude -p` invocation, note assembly, file write, `Index.md` update) must run in a detached background process that survives the parent Claude Code session tearing down. | Must |
| FR2 | The detached worker must log its lifecycle events (start, `claude -p` exit, file write, index update, any failure) to `~/.claude/obsidian-memory/distill-debug.log` when debug logging is enabled, so `/clear`-path failures are diagnosable without re-instrumentation. | Should |
| FR3 | Exactly one note must be written per `SessionEnd` invocation — no duplicate notes must appear when the `claude -p` subprocess's own `SessionEnd` hook (unavoidable side-effect of `claude -p`) fires. | Must |

---

## Out of Scope

- Fixing the `${CLAUDE_PLUGIN_ROOT}` unexpanded-variable stderr noise printed by the recursive `claude -p` subprocess's own `SessionEnd` hook — cosmetic, a separate issue.
- Configuring or raising the Claude Code `SessionEnd` hook timeout via `settings.json` — the harness-side knob is out of this plugin's scope.
- Changes to the RAG (`UserPromptSubmit`) hook or other unrelated hooks.
- Refactoring `vault-distill.sh` beyond what's required to decouple the synchronous block from the fast-return path.
- Removing the debug-logging instrumentation added during investigation (tracked as follow-up housekeeping, not part of this fix).

---

## Validation Checklist

Before moving to PLAN phase:

- [x] Reproduction steps are repeatable and specific
- [x] Expected vs actual behavior is clearly stated
- [x] Severity is assessed (High — primary plugin value is broken on the most common context-reset operation)
- [x] Acceptance criteria use Given/When/Then format
- [x] At least one regression scenario is included (AC2, AC3)
- [x] Fix scope is minimal — no feature work mixed in
- [x] Out of scope is defined
