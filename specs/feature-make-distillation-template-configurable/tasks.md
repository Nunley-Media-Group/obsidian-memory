# Tasks: Configurable distillation template

**Issues**: #7
**Date**: 2026-04-22
**Status**: Planning
**Author**: Rich Nunley

---

## Summary

| Phase | Tasks | Status |
|-------|-------|--------|
| Setup | 2 | [ ] |
| Backend | 4 | [ ] |
| Integration | 2 | [ ] |
| Testing | 4 | [ ] |
| **Total** | 12 | |

There is no Frontend phase — obsidian-memory has no UI layer (per `steering/structure.md`). Skill-output changes (FR7 in the doctor skill) are grouped under Integration.

---

## Task Format

Each task follows:

```
### T[NNN]: [Task Title]

**File(s)**: `path/to/file`
**Type**: Create | Modify | Delete
**Depends**: T[NNN] (or None)
**Acceptance**:
- [ ] [Verifiable criterion]

**Notes**: [Optional implementation hints]
```

---

## Phase 1: Setup

### T001: Create the `templates/` directory with the bundled default template

**File(s)**: `templates/default-distillation.md`
**Type**: Create
**Depends**: None
**Acceptance**:
- [ ] The file exists at `<repo-root>/templates/default-distillation.md`.
- [ ] The file's contents are a byte-for-byte transcription of the current `PROMPT="..."` string in `scripts/vault-distill.sh` (lines 92–117), with the one `${SLUG}` reference replaced by the literal token `{{project_slug}}`.
- [ ] The file ends with a single trailing newline.
- [ ] The file contains no YAML frontmatter block (the default emits the hook's seven-field frontmatter, so the template must not have its own).

**Notes**: This file is the **sole source of truth** for the v0.1 layout after T002 strips the inline prompt from the hook. The golden-fixture hash assertion from T012 runs against this file; any future edit will surface as a failing AC2 scenario. Keep the "TRANSCRIPT:" marker at the tail — the hook currently appends the conversation after that marker, and AC2 requires byte-identity with the v0.1 prompt.

### T002: Carve out space in `_common.sh` for the new helpers

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: None
**Acceptance**:
- [ ] A new section comment `# --- Template resolution, frontmatter split, variable substitution (issue #7) ---` is appended at the bottom of `_common.sh` immediately above three stub functions `om_resolve_distill_template`, `om_split_frontmatter`, `om_render`.
- [ ] Each stub echoes a deterministic sentinel (`# NOT_IMPLEMENTED_T003/T004/T005`) so downstream tasks can be implemented and unit-tested independently.
- [ ] `bats tests/unit/common.bats` still passes against the existing `_common.sh` API surface — no existing helper is renamed or relocated.

**Notes**: This task is purely structural. It exists so T003/T004/T005 can be independently reviewable diffs instead of one 150-line change.

---

## Phase 2: Backend Implementation

### T003: Implement `om_render` — whitelisted variable substitution

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: T002
**Acceptance**:
- [ ] `om_render` reads the candidate text from its single positional argument (`$1`) and reads the six substitution values from its environment: `SLUG`, `NOW_DATE`, `NOW_TIME`, `SESSION_ID`, `TRANSCRIPT`, `CONVO` (the last substitutes `{{transcript}}`).
- [ ] Implementation uses a single `jq -Rn --arg text "$1" --arg project_slug "$SLUG" --arg date "$NOW_DATE" --arg time "$NOW_TIME" --arg session_id "$SESSION_ID" --arg transcript_path "$TRANSCRIPT" --arg transcript "$CONVO"` invocation with chained `gsub("\\{\\{project_slug\\}\\}"; $project_slug) | gsub(…)` calls for each of the six tokens.
- [ ] No subprocess other than the single `jq` is spawned.
- [ ] On jq failure (rare — hard filesystem error), the function echoes the input text unchanged and returns 0. The hook never exits non-zero because of a substitution problem.
- [ ] Shellcheck clean.

**Notes**: Use `--arg text "$1"` (not `--rawfile`) because the input is already a bash string, not a file. `--rawfile` is reserved for the template-file read in T006. Make the gsub pattern a shared constant or inlined uniformly so T011's regex-footgun test can pin the exact literal pattern.

### T004: Implement `om_split_frontmatter` — YAML frontmatter detection and split

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: T002
**Acceptance**:
- [ ] `om_split_frontmatter` takes a single positional arg (the full template contents) and prints two regions to stdout separated by a single 0x1E (record separator) byte: `<frontmatter><0x1E><body>`.
- [ ] Detection: if the first non-empty line is exactly `---` AND a subsequent line is exactly `---`, split. Otherwise the frontmatter is empty and the body is the entire input.
- [ ] The split is inclusive on both `---` lines into the frontmatter region; the body region begins on the line immediately after the closing `---`.
- [ ] Implementation uses `awk` (POSIX) — no bash 4+ features, no `mapfile`, no `readarray`.
- [ ] A malformed template (opening `---` with no closing `---`) is treated as having no frontmatter; the entire text falls into the body region.
- [ ] Shellcheck clean.

**Notes**: The 0x1E separator is a single byte unlikely to appear in Markdown; `printf '\x1E'` is the emit. Callers split on it via `IFS=$'\x1E' read -r fm body < <(om_split_frontmatter "$tmpl")`.

### T005: Implement `om_resolve_distill_template` — resolution + fallback + stderr logging

**File(s)**: `scripts/_common.sh`
**Type**: Modify
**Depends**: T002
**Acceptance**:
- [ ] `om_resolve_distill_template` takes a single positional arg `$slug` and echoes one absolute path.
- [ ] Resolution order: (a) `projects.overrides.<slug>.distill.template_path`, (b) `distill.template_path`, (c) `<plugin-root>/templates/default-distillation.md` where `<plugin-root>` is derived from `$(dirname "$0")/..`.
- [ ] A path is used when `[ -r "$path" ] && [ -s "$path" ]` (readable regular file, non-empty).
- [ ] When a configured path (a) or (b) exists as a string but fails the readable/non-empty check, exactly one stderr line is emitted: `[vault-distill.sh] distill.template_path=<path> unreadable; falling back to default template`. The scope (a or b) is identifiable by including the slug in the message when (a) failed: `[vault-distill.sh] projects.overrides.<slug>.distill.template_path=<path> unreadable; falling back to default template`.
- [ ] Only one stderr line per invocation — if both (a) and (b) are configured-but-broken, log once for whichever is consulted first (the override), and silently fall through.
- [ ] Returns 0 always. The bundled default's existence is an invariant of the plugin install, not a runtime check.
- [ ] Relative paths in config are resolved against `$HOME` (`case "$path" in /*) ;; *) path="$HOME/$path" ;; esac`).
- [ ] Shellcheck clean.

**Notes**: Read the two config paths in a single `jq -r` for efficiency: `.projects.overrides."'"$slug"'".distill.template_path // "", .distill.template_path // ""` — guard the slug with `@sh` or by quoting appropriately (slug charset is `[a-z0-9-]`, so direct interpolation is safe).

### T006: Integrate the three helpers into `vault-distill.sh`

**File(s)**: `scripts/vault-distill.sh`
**Type**: Modify
**Depends**: T003, T004, T005
**Acceptance**:
- [ ] The inline `PROMPT="You are distilling…${CONVO}"` block (current lines 92–117) is removed.
- [ ] After `CONVO` is built, the hook calls:
  1. `TEMPLATE_PATH="$(om_resolve_distill_template "$SLUG")"`
  2. `TMPL_RAW="$(cat "$TEMPLATE_PATH" 2>/dev/null)"` — if empty, re-resolve against the bundled default and log once.
  3. `IFS=$'\x1E' read -rd '' FM_RAW BODY_RAW < <(om_split_frontmatter "$TMPL_RAW")`
  4. `FM_OUT="$(om_render "$FM_RAW")"`
  5. `PROMPT="$(om_render "$BODY_RAW")"`
- [ ] The `NOTE_BODY="$(CLAUDECODE="" claude -p "$PROMPT" 2>/dev/null)"` call is unchanged.
- [ ] Output emission logic:
  - When `FM_OUT` is non-empty, the output file contents are `${FM_OUT}\n\n${NOTE_BODY}` (or the legacy empty-body fallback if `NOTE_BODY` is empty).
  - When `FM_OUT` is empty, the hook emits the existing seven-field frontmatter block unchanged, followed by `${NOTE_BODY}`.
- [ ] The Index.md update logic is untouched.
- [ ] The hook still exits 0 on every terminating path.
- [ ] Shellcheck clean.

**Notes**: If `TMPL_RAW` is empty after a cat from the resolved path, re-run `om_resolve_distill_template` with an env flag that forces the bundled default and log once — this handles a narrow race where the user deletes the configured template between `om_resolve_distill_template`'s `[ -s ]` check and the `cat`. The simpler path: do not implement that race guard; rely on `om_resolve_distill_template`'s `[ -s ]` check being sufficient in practice.

---

## Phase 3: Integration

### T007: Doctor skill reports the active template

**File(s)**: `scripts/vault-doctor.sh`, `skills/doctor/SKILL.md` (if output format is documented there)
**Type**: Modify
**Depends**: T005
**Acceptance**:
- [ ] `vault-doctor.sh` adds a new line to its output of the form:
  - `distill template: default (bundled)` — when neither config key is set.
  - `distill template: global: <path>` — when only `distill.template_path` is set and readable.
  - `distill template: project-override(<slug>): <path>` — when a per-project override is set and readable. The `<slug>` here is the slug of the project doctor is run against (doctor already knows how to compute this).
  - `distill template: configured but unreadable — falling back to default` — when the configured path fails the readable/non-empty check.
- [ ] Doctor reuses `om_resolve_distill_template` and inspects the stderr it produces to distinguish "configured but unreadable" from the readable cases. The cleanest way: doctor calls a new thin helper `om_describe_distill_template "$slug"` that returns the descriptor string without emitting its own stderr.
- [ ] The new line appears in the doctor output whether or not `distill.enabled` is true — an unreadable path is worth reporting even when distill is off.
- [ ] Existing doctor output lines are unchanged in order and format.

**Notes**: If FR7's Should priority is deferred in implementation, T007 can be marked complete with a no-op in doctor — but the acceptance criteria here pin the exact string format, so defer by skipping the task, not by emitting different strings.

### T008: Update SKILL.md for setup (and teardown, if it mirrors config)

**File(s)**: `skills/setup/SKILL.md`, `skills/teardown/SKILL.md` (read-only check)
**Type**: Modify
**Depends**: T001, T005
**Acceptance**:
- [ ] Setup SKILL.md documents the `distill.template_path` config key under a new "Customizing the distillation template" section.
- [ ] The section describes the copy-and-edit flow: `cp <plugin-root>/templates/default-distillation.md ~/.claude/obsidian-memory/templates/my-template.md`, then edit the config to point at it.
- [ ] The section lists the six whitelist variables and notes that `$VAR`, backticks, `$()`, and `${…}` in templates are NOT expanded.
- [ ] The section notes that a template with a YAML frontmatter block replaces the default seven-field frontmatter.
- [ ] Teardown SKILL.md is inspected — if it removes config keys, it is updated to also remove `distill.template_path` and `projects.overrides.<slug>.distill.*`. If teardown already removes the whole config file on uninstall (check first), no change is needed.

**Notes**: Both skill docs are Markdown-only — no behavior change beyond the doctor integration in T007.

---

## Phase 4: BDD Testing (Required)

**Every acceptance criterion MUST have a Gherkin scenario.** Step definitions live under `tests/features/steps/vault-distill.sh` (extending the existing file, not a new one).

### T009: Author the BDD feature file

**File(s)**: `specs/feature-make-distillation-template-configurable/feature.gherkin`
**Type**: Create
**Depends**: T006
**Acceptance**:
- [ ] The feature file contains one Scenario per requirements.md AC (AC1 through AC5).
- [ ] Each scenario uses concrete fixture values (not placeholders like `<slug>`): a realistic slug such as `widgets`, a fixed date like `2026-04-22`, and a small transcript fixture.
- [ ] The file includes a `Background:` block that sets up `$VAULT`, installs the plugin against a scratch `$HOME`, writes a config with `distill.enabled=true`, and seeds a minimal 2-KB transcript.
- [ ] The feature is valid Gherkin syntax (`tests/run-bdd.sh` parses it without error — though the steps may fail until T010 lands).

**Notes**: Reuse scenario-naming style from `specs/feature-session-distillation-hook/feature.gherkin` for consistency.

### T010: Implement the new BDD step definitions

**File(s)**: `tests/features/steps/vault-distill.sh`, `tests/fixtures/distill/v0.1-prompt.txt` (new golden file)
**Type**: Modify (steps file) and Create (golden fixture)
**Depends**: T001, T006, T009
**Acceptance**:
- [ ] New Given/When/Then steps exist for each scenario-specific phrase from T009's feature file (e.g., `a template at "$path" with body: <doc-string>`, `the prompt sent to claude -p is byte-identical to the v0.1 prompt`).
- [ ] The golden fixture `tests/fixtures/distill/v0.1-prompt.txt` is a copy of the pre-change inline `PROMPT="..."` content (captured before T001 removes it) for use in AC2's byte-equality assertion.
- [ ] The `claude -p` stub used by the test harness is reused unchanged — no new stubs added.
- [ ] All 5 scenarios from the feature file pass: `tests/run-bdd.sh` exits 0 for this feature.
- [ ] Shellcheck clean on any new step definitions.

**Notes**: AC2's scenario compares the prompt string the hook sends to `claude -p`, not the final note content. The test harness already intercepts the stub's argv; extend it to log the prompt to a file the scenario can diff against the golden fixture.

### T011: Author unit tests for the three new helpers

**File(s)**: `tests/unit/template.bats`
**Type**: Create
**Depends**: T003, T004, T005
**Acceptance**:
- [ ] `om_render` tests cover: each of 6 whitelist vars replaced; non-whitelist `{{foo}}` preserved; `$HOME`/backticks/`$(…)`/`${…}` preserved; empty input → empty output; multi-occurrence `{{project_slug}}` all replaced; `{{project_slugger}}` not partial-matched (regex footgun guard).
- [ ] `om_split_frontmatter` tests cover: no frontmatter → empty FM; well-formed FM → FM + body; malformed FM (open-only) → empty FM + full input; template starting with `---` followed by only `---` and nothing else (edge: FM present but body empty).
- [ ] `om_resolve_distill_template` tests cover: all three resolution tiers; unreadable configured path falls back with one stderr line; empty configured file falls back with one stderr line; per-project override with mismatched slug is ignored; relative path in config resolves against `$HOME`.
- [ ] `bats tests/unit/template.bats` exits 0.

**Notes**: Use `$BATS_TEST_TMPDIR` as the scratch `$HOME`. Never touch the operator's real `~/.claude`.

### T012: Freeze the default-template byte-identity check

**File(s)**: `tests/unit/default-template.bats`
**Type**: Create
**Depends**: T001, T010
**Acceptance**:
- [ ] A single bats test asserts the SHA-256 of `templates/default-distillation.md` matches a hash literal stored in the test file. The hash is computed once from the initial check-in of T001 and pinned.
- [ ] The test's failure message explains how to update the hash intentionally (the message names the expected file and the command `shasum -a 256 templates/default-distillation.md`).
- [ ] `bats tests/unit/default-template.bats` exits 0 at check-in.

**Notes**: This is the drift guard from design.md → Risks. Without it, a future editor can silently change the default template, breaking AC2 for every user who has not configured a template. The test is intentionally precious — it should fail loudly, and the remediation path is a deliberate hash update in the same commit as the template change.

---

## Dependency Graph

```
T001 ────────────────┬──▶ T010 ──▶ (uses golden fixture)
                     │
                     └──▶ T012

T002 ──┬──▶ T003 ────┼──▶ T006 ──▶ T009 ──▶ T010
       │             │
       ├──▶ T004 ────┤
       │             │
       └──▶ T005 ────┴──▶ T007
                     │
                     └──▶ T008
                     
T003, T004, T005 ──▶ T011
```

Critical path: **T002 → T005 → T006 → T009 → T010** (the end-to-end BDD path). T001 / T011 / T012 run in parallel off the critical path.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #7 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to IMPLEMENT phase:

- [x] Each task has a single responsibility
- [x] Dependencies are correctly mapped (see Dependency Graph above)
- [x] Tasks can be completed independently once their dependencies land (T003/T004/T005 can run in parallel after T002)
- [x] Acceptance criteria are verifiable (every task acceptance is either a file check, a shellcheck pass, or a bats/BDD run)
- [x] File paths reference actual project structure per `steering/structure.md` (`scripts/`, `tests/`, `skills/`, plus the new `templates/` top-level dir)
- [x] Test tasks are included for each layer (unit: T011, T012; integration/BDD: T009, T010)
- [x] No circular dependencies
- [x] Tasks are in logical execution order (Setup → Backend → Integration → Testing)
