# Design: bats-core + cucumber-shell test harness

**Issues**: #1
**Date**: 2026-04-19
**Status**: Approved
**Author**: Rich Nunley

---

## Overview

The harness introduces a `tests/` tree matching the layout declared in `steering/structure.md`, a shared bats helper that forces every test under a scratch `$HOME` and scratch vault, and a hand-rolled `tests/run-bdd.sh` that implements the cucumber-shell contract in ~100 lines of plain bash. All five Verification Gates in `steering/tech.md` become real: `bats tests/unit`, `bats tests/integration`, `tests/run-bdd.sh`, `shellcheck …`, and `jq empty …`.

The key design decision is to **implement cucumber-shell ourselves as a thin bash runner** rather than depend on an upstream package. The `cucumber-shell` name in `steering/tech.md` refers to the *contract* (step-definition lookup by function-name convention, Gherkin parsing line-by-line, exit 0 iff every scenario passes), not a specific external binary. A hand-rolled runner keeps the plugin's "plain shell, no new runtime deps beyond `jq` + `bats` + `shellcheck`" ethos, avoids pinning a poorly-maintained external project, and is the same blast-radius-zero approach used for the rest of the plugin.

Beyond the runner, the harness authors step-definition libraries for all four baseline feature specs (#9 vault-setup, #10 RAG injection, #11 session distillation, #12 manual distill-session skill) so that `tests/run-bdd.sh` exits 0 against the current shipped behavior. Hook scripts run against the scratch vault using the helper. The nested `claude -p` subprocess used by the distillation path (#11, #12) is replaced at test time with a **deterministic fake binary on `$PATH`** so distillation scenarios do not spawn real Claude CLI invocations.

The harness is additive. It creates new files under `tests/` and `specs/example/`, touches `README.md` for the Development section, and optionally edits `scripts/vault-rag.sh` / `scripts/vault-distill.sh` only to fix pre-existing shellcheck findings. No hook wiring, no plugin manifest, and no existing `specs/*` requirements / design / tasks / gherkin file is modified.

---

## Architecture

### Component Diagram

```
┌────────────────────────────────────────────────────────────────────────────┐
│                     Developer CLI (dev-time only)                           │
│                                                                              │
│  bats tests/unit          bats tests/integration        tests/run-bdd.sh     │
│        │                         │                             │             │
│        ▼                         ▼                             ▼             │
│  ┌──────────────┐        ┌──────────────────┐         ┌─────────────────┐  │
│  │ tests/unit/  │        │ tests/integration│         │  run-bdd.sh     │  │
│  │  *.bats      │        │   *.bats         │         │  (bash runner)  │  │
│  └──────┬───────┘        └──────┬───────────┘         └────────┬────────┘  │
│         │                        │                              │            │
│         │                        │  load helper                 │ glob       │
│         │                        ▼                              ▼            │
│         │             ┌────────────────────────┐      specs/*/feature.gherkin│
│         │             │ tests/helpers/         │                │            │
│         │             │   scratch.bash         │                │ parse      │
│         │             │ - HOME=tmp             │                ▼            │
│         │             │ - scratch vault        │      tests/features/steps/  │
│         │             │ - PLUGIN_ROOT          │             *.sh            │
│         │             │ - assert_home_untouched│                │            │
│         │             └────────────────────────┘                │ exec       │
│         │                                                       ▼            │
│         │                                              scratch.bash loaded   │
│         ▼                                              + step functions      │
│  shellcheck gate ──────────────▶ scripts/*.sh + tests/**/*.sh                │
│  jq-validity gate ─────────────▶ .claude-plugin/plugin.json + hooks.json     │
└────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow — `bats tests/integration`

```
1. Developer runs `bats tests/integration`.
2. bats discovers every `tests/integration/*.bats` file.
3. Each .bats file `load 'helpers/scratch'` in its `setup()`.
4. scratch.bash:
   a. Captures REAL_HOME before mutation (for assert_home_untouched).
   b. Snapshots REAL_HOME/.claude via `find … -printf` digest.
   c. Exports HOME=$BATS_TEST_TMPDIR/home; mkdir -p $HOME/.claude.
   d. Creates scratch vault at $BATS_TEST_TMPDIR/vault.
   e. Exports PLUGIN_ROOT (repo root, resolved from BATS_TEST_DIRNAME).
5. Test body runs.
6. teardown() calls assert_home_untouched → re-computes the digest and fails if changed.
7. bats reports TAP; exit 0 iff all pass.
```

### Data Flow — `tests/run-bdd.sh`

```
1. Developer runs `tests/run-bdd.sh`.
2. Runner globs `specs/*/feature.gherkin`.
3. For each feature file:
   a. Parse Feature/Scenario/Given/When/Then/And lines sequentially.
   b. Source every tests/features/steps/*.sh into a fresh subshell per scenario.
   c. Source tests/helpers/scratch.bash to provide scratch vault + HOME.
   d. For each step, normalize the step text to a function name
      (e.g., 'Given an empty vault at "$VAULT"' → given_an_empty_vault_at).
      Rule: lowercase, strip quoted literals, replace non-alnum runs with '_',
      collapse underscores, strip trailing underscore.
   e. If the function is defined, call it with the quoted-literal args in order.
   f. If undefined, print "undefined step: <text>" to stderr and mark the scenario failed.
4. Runner prints a final summary: "<N> scenarios, <M> passed, <K> failed, <U> undefined steps".
5. Exit 0 iff M == N and K == 0 and U == 0.
```

---

## API / Interface Changes

### New interfaces

| Interface | Type | Purpose |
|-----------|------|---------|
| `tests/run-bdd.sh` | executable shell script | Implements the cucumber-shell contract against `specs/*/feature.gherkin` |
| `tests/helpers/scratch.bash` | bash helper sourced by bats tests | Exports scratch `$HOME`, scratch vault, `$PLUGIN_ROOT`; provides `assert_home_untouched` |
| `tests/features/steps/*.sh` | step-definition library | One file per feature; functions named after normalized step text |

### Baseline step-definition layout

One step file per baseline feature, each self-contained and named to match `/write-spec`'s convention:

| File | Covers | Key fixtures |
|------|--------|--------------|
| `tests/features/steps/setup.sh` | `specs/feature-vault-setup/feature.gherkin` (#9) | Scratch `$HOME`, scratch vault; invokes the `/obsidian-memory:setup` behavior by sourcing the skill logic or executing the shipped shell equivalent |
| `tests/features/steps/rag.sh` | `specs/feature-rag-prompt-injection/feature.gherkin` (#10) | Scratch vault pre-populated with fixture notes; pipes a JSON hook payload into `scripts/vault-rag.sh` and captures stdout |
| `tests/features/steps/distill.sh` | `specs/feature-session-distillation-hook/feature.gherkin` (#11) | Scratch `$HOME/.claude/projects/<slug>/*.jsonl` transcript; fake `claude` binary on `$PATH` (see below); invokes `scripts/vault-distill.sh` |
| `tests/features/steps/manual-distill.sh` | `specs/feature-manual-distill-skill/feature.gherkin` (#12) | Same fixtures as distill.sh; invokes the `/obsidian-memory:distill-session` skill behavior |
| `tests/features/steps/common.sh` | Shared background steps ("a scratch HOME at …", "a scratch vault at …") used across every baseline `Background:` block | Loaded first by the runner so every feature's Background resolves |

Load order inside `tests/run-bdd.sh` is: `common.sh` first, then any other `*.sh` the feature references. If a step text normalizes to a function defined in multiple step files, the runner emits a warning and uses the most specific (non-common) match.

### Fake `claude` binary for distillation scenarios

Scenarios that invoke `scripts/vault-distill.sh` or `/obsidian-memory:distill-session` would otherwise spawn a real `claude -p` subprocess, which is non-deterministic, network-touching, and session-polluting. The helper sets up a fake `claude` on `$PATH` before each such scenario:

```bash
# tests/helpers/fake-claude.bash — called from step defs that need deterministic distillation
install_fake_claude() {
  local bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<'FAKE'
#!/usr/bin/env bash
# Deterministic fake: reads stdin (the distillation prompt) and emits a canned
# markdown note that matches the template vault-distill.sh expects.
cat <<'NOTE'
---
project: scratch-project
---

# Session — scratch

## Decisions
- Fake decision from fake claude

## Patterns
- Fake pattern

## Open Threads
- None
NOTE
FAKE
  chmod +x "$bindir/claude"
  PATH="$bindir:$PATH"
  export PATH
}
```

The fake is installed by `common.sh` whenever a scenario's Background references distillation, or explicitly by `distill.sh` / `manual-distill.sh`. It is torn down implicitly when `$BATS_TEST_TMPDIR` is cleaned up.

### Step-definition contract

```bash
# tests/features/steps/<feature-slug>.sh — one file per feature
#
# Conventions:
#   - One function per Given/When/Then phrase.
#   - Function names are the normalized step text: lowercase, non-alnum → '_',
#     collapsed, trailing '_' stripped. Leading Given/When/Then/And is stripped.
#   - Quoted literals ("...") and numeric literals are passed as positional args
#     in the order they appear in the step text.
#   - All filesystem state lives under $BATS_TEST_TMPDIR (scratch vault, scratch HOME).
#   - Never touch the operator's real ~/.claude or real Obsidian vault.

# Step: Given an Obsidian vault at "$VAULT" containing "my-note.md" with the text "jq is used"
an_obsidian_vault_at_containing_with_the_text() {
  local vault="$1" file="$2" text="$3"
  mkdir -p "$vault"
  printf '%s\n' "$text" > "$vault/$file"
}
```

### Runner exit-code contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Every scenario passed; every step found a matching definition |
| `1` | ≥1 scenario failed an assertion |
| `2` | ≥1 step was undefined (no matching function in `tests/features/steps/*.sh`) |
| other | Internal runner failure (unparseable Gherkin, missing specs dir) — stderr has the reason |

AC3's negative path relies on exit code `2`.

### Gate command contract (matches `steering/tech.md` Verification Gates table)

| Gate | Command |
|------|---------|
| Shellcheck | `shellcheck scripts/*.sh tests/**/*.sh 2>/dev/null \|\| shellcheck $(find scripts tests -name '*.sh')` |
| Unit Tests | `bats tests/unit` |
| Integration Tests | `bats tests/integration` |
| BDD Tests | `tests/run-bdd.sh` |
| JSON validity | `jq empty .claude-plugin/plugin.json hooks/hooks.json` |

FR9 binds these byte-for-byte to `steering/tech.md`. If a rename is ever required, the `tech.md` row changes in the same commit as the harness rename.

---

## Database / Storage Changes

Not applicable. The harness is filesystem-only and scratch-scoped. No database, no migration.

---

## State Management

Not applicable in the traditional UI sense. The harness does have a few pieces of **test-scoped state** worth enumerating so every helper respects them:

| State | Where set | Where used | Lifetime |
|-------|-----------|------------|----------|
| `$REAL_HOME` | `scratch.bash` (before mutating `$HOME`) | `assert_home_untouched` | One bats test |
| `$HOME` | `scratch.bash` (overridden) | Every hook invocation inside a test | One bats test |
| `$PLUGIN_ROOT` | `scratch.bash` (from `BATS_TEST_DIRNAME`) | Step definitions invoking `scripts/*.sh` | One bats test |
| Real-`$HOME`/`.claude` digest | `scratch.bash` `setup()` | `assert_home_untouched` in `teardown()` | One bats test |

No state is shared across tests. Each bats test gets a fresh `$BATS_TEST_TMPDIR`, and each BDD scenario runs in a fresh subshell sourced from scratch.

---

## UI Components

Not applicable. The only operator-facing surface is the `bats` TAP output, `tests/run-bdd.sh` summary line, and the `README.md` Development section.

---

## Alternatives Considered

| Option | Description | Pros | Cons | Decision |
|--------|-------------|------|------|----------|
| **A: Depend on upstream `cucumber-shell`** | Install `cucumber-shell` from npm/brew/apt as an external dep | Off-the-shelf; no runner to maintain | Package availability is inconsistent across platforms; adds a pin we don't own; runner surface is small enough that we don't need it | Rejected — adds a fragile dependency to a plugin whose entire ethos is "plain shell" |
| **B: Hand-roll a bash BDD runner (`tests/run-bdd.sh`)** | Parse Gherkin line-by-line, dispatch to step-def functions by normalized name | Zero new deps; matches plugin ethos; code is inspectable; AC3 negative path is trivial to implement (exit 2) | We own the parser; need to test it | **Selected** |
| **C: Use shellspec's Gherkin mode** | `shellspec` is a more widely packaged bash test runner with some Gherkin support | Mature, cross-platform | Would duplicate bats' role; `tech.md` already declares bats — two runners doubles install surface | Rejected — conflicts with the existing `bats` choice in `tech.md` |
| **D: Skip cucumber-shell entirely, write BDD as bats tests** | Drop the Gherkin layer; write every spec as a `*.bats` file | Simplest tooling | Breaks `/write-spec`'s contract — every `feature.gherkin` would be orphaned; loses the "plain Gherkin is the acceptance criterion" property | Rejected — breaks nmg-sdlc contract |

**Placeholder location (AC3 subject):**

| Option | Description | Decision |
|--------|-------------|----------|
| **A: `specs/example/feature.gherkin`** | Lives under `specs/` so `tests/run-bdd.sh`'s natural glob picks it up | **Selected** — satisfies AC3 with no special-case in the runner; `specs/example/` is clearly marked "safe to delete" |
| **B: `tests/features/example/feature.gherkin`** | Lives under `tests/` so it's out of the production spec set | Rejected — requires the runner to glob two trees; one-tree glob is simpler |

---

## Security Considerations

- [x] **Authentication**: N/A — harness is dev-time only.
- [x] **Authorization**: Every integration test runs with `HOME=$BATS_TEST_TMPDIR/home`. `assert_home_untouched` is the hard backstop that fails the test if anything leaks out.
- [x] **Input Validation**: `tests/run-bdd.sh` treats Gherkin input as untrusted-but-developer-authored. It never `eval`s step text; it normalizes to a function name and dispatches. Quoted literals from step text are passed as argv, never as a command string.
- [x] **Data Sanitization**: Step text normalization is a pure `tr`/`sed` pipeline — no shell interpolation of the raw step text.
- [x] **Sensitive Data**: None handled. The harness does not read `~/.claude/obsidian-memory/config.json` or any real config.

---

## Performance Considerations

- [x] **Caching**: None. Tests are fast enough (< 10 s for unit+integration) that caching would add maintenance cost for negligible win.
- [x] **Pagination**: N/A.
- [x] **Lazy Loading**: `tests/run-bdd.sh` only sources step definitions for features it actually runs — no global source of `tests/features/steps/*.sh` at startup beyond the scenario scope.
- [x] **Indexing**: N/A.

---

## Testing Strategy

The harness *is* the testing strategy. The meta-tests for the harness itself are:

| Layer | Type | Coverage |
|-------|------|----------|
| `scratch.bash` | bats unit | `assert_home_untouched` passes on no-op; fails when a file is created under `$REAL_HOME/.claude` (verify the backstop works) |
| `scratch.bash` | bats integration | Smoke: sourcing the helper sets `HOME`, creates scratch vault, exports `PLUGIN_ROOT` |
| `tests/run-bdd.sh` | bats integration | Runs against `specs/example/feature.gherkin` (AC3 happy path); runs against the same feature with the step file removed (AC3 negative path — asserts exit code 2) |
| Baseline BDD | BDD via `tests/run-bdd.sh` | Every scenario in each of the four baseline features exits green (AC8). Exercises the shipped hook scripts + skills end-to-end against the scratch vault. |
| Full gate sweep | Integration (manual + AC7) | All five gate commands from `tech.md` exit 0 on the current repo |

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Hand-rolled Gherkin parser has edge-case bugs (multiline strings, doc strings, tables) | Med | Med | Support only the Gherkin subset the current specs actually use — Feature, Scenario, Given/When/Then/And, quoted literals. Document the supported subset in the runner's header comment. Add unsupported-feature warnings. |
| Step-name normalization collisions (two different step texts map to the same function name) | Low | Med | If normalization collides, the second `function foo() {}` definition silently shadows the first. Mitigation: the runner logs a warning when the same function name is defined twice across step files, and a lint task (future) can flag it. |
| `assert_home_untouched` false positives (real `~/.claude` changes mid-test due to unrelated Claude Code activity) | Low | Low | The digest includes only files; timing-based fields are excluded. Document that developers should not run tests while a Claude Code session is actively writing to `~/.claude/projects/`. |
| `bats` / `shellcheck` availability on fresh machines | Med | Low | README Development section has explicit brew / apt commands (FR8). Missing deps fail loudly on first invocation. |
| Drift between `steering/tech.md` gate commands and `tests/run-bdd.sh` | Med | High | FR9: the two must be byte-identical. Any rename goes through both in the same commit. AC7 validates end-to-end. |
| Baseline scenarios reveal ambiguous Gherkin wording (step phrase cannot be normalized to a single function) | Med | Med | Treated as a spec-authoring finding, not a harness bug. The harness logs the undefined step and fails; the fix is a spec rewording landed against the originating issue (#9–#12), not a runner hack. Out of Scope in requirements.md documents this. |
| Fake `claude` binary drifts from what `scripts/vault-distill.sh` expects | Low | Med | Fake output is kept minimal — only the frontmatter + section structure the script parses. Any schema change in the distill template changes both in the same commit. |
| Skill behavior (`/obsidian-memory:setup`, `/obsidian-memory:distill-session`) is authored as markdown SKILL.md files, not executable scripts, so step defs cannot "invoke" them directly | High | Med | Step defs invoke the **shipped shell equivalents** (the imperative steps documented in each SKILL.md, translated to a bash helper in the step file). The helper reproduces the skill's filesystem behavior; the skill's prose documents the contract. This is documented in each step-def file's header. |

---

## Open Questions

- [ ] None — the cucumber-shell tooling choice and placeholder location are resolved in Alternatives Considered above.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #1 | 2026-04-19 | Initial design — hand-rolled BDD runner + bats scratch helper |
| #1 | 2026-04-19 | Added baseline step-definition layout (#9, #10, #11, #12) and fake `claude` binary strategy for deterministic distillation scenarios |

---

## Validation Checklist

- [x] Architecture follows existing project patterns (per `structure.md` — `tests/` layout matches §Project Layout exactly)
- [x] All interface changes documented (step-def contract, runner exit codes, gate commands)
- [x] No database/storage changes (N/A)
- [x] State management approach is clear (enumerated test-scoped state)
- [x] No UI components (N/A)
- [x] Security considerations addressed (scratch-`$HOME` + `assert_home_untouched`; no `eval` of step text)
- [x] Performance impact analyzed (< 10 s unit+integration target)
- [x] Testing strategy defined (meta-tests for the harness itself)
- [x] Alternatives were considered and documented (cucumber-shell tooling, placeholder location)
- [x] Risks identified with mitigations
