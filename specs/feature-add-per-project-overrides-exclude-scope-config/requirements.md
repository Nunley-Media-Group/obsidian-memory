# Requirements: Per-Project Overrides (Exclude / Scope Config)

**Issues**: #6
**Date**: 2026-04-22
**Status**: Draft
**Author**: Rich Nunley

---

## User Story

**As a** Claude Code + Obsidian user who sometimes works on a confidential or client project I must not leak into my personal vault
**I want** to exclude specific projects from RAG injection and session distillation
**So that** client code and prompts never end up in my Obsidian notes while I keep zero-config coverage on the rest of my projects.

---

## Background

obsidian-memory is installed at user scope (`steering/product.md` → Core Value Proposition #1). Its hooks fire on every Claude Code session, every project, on the machine — that is the product's core value proposition, and it is also a sharp edge. A user on a confidential project today has only two options: globally flip `rag.enabled` / `distill.enabled` off via `/obsidian-memory:toggle` (issue #4), which kills the plugin for *every* project for the rest of the session, or hand-edit `~/.claude/obsidian-memory/config.json` with ad-hoc logic that does not exist yet.

`steering/product.md` → Feature Prioritization → "Could Have" names this capability explicitly: *"Per-project overrides (e.g., exclude a project from distillation)"*. This spec promotes it into the v1 MVP scope for the reason the issue states: per-project overrides let a user scope the plugin without giving up zero-config for the rest of their projects.

The current state relevant to this work:

- `~/.claude/obsidian-memory/config.json` is a flat JSON object with `vaultPath`, `rag.enabled`, `distill.enabled`. There is no `projects` stanza.
- Both hooks (`scripts/vault-rag.sh` dispatcher and `scripts/vault-distill.sh`) load config via `scripts/_common.sh` → `om_load_config`, which gates on `vaultPath` and `<feature>.enabled`. Neither consults any per-project state.
- `scripts/_common.sh` already exports a slug helper (`om_slug`) that lowercases, non-alphanum→dash, collapses, trims. It does NOT length-cap at 60 — the documented convention in `steering/structure.md` → Naming Conventions says slugs should be length-capped at 60, and `steering/structure.md` → Anti-Patterns → "Not pinning the slug allowlist" names the 60-char cap as a filesystem-safety requirement. This spec closes that gap because the per-project scope matcher depends on slug stability.
- `vault-distill.sh` reads `cwd` from its `SessionEnd` payload; the UserPromptSubmit payload consumed by `vault-rag.sh` is smaller — this spec pins `cwd` resolution for both hooks so the scope check runs against a stable project identity. Where the hook payload does not carry a cwd, the hook falls back to the process's current working directory (`$PWD`).

**UX decision on FR4 (the scoped-skill location).** The issue's Notes call this out as a UX call for the spec to resolve: extend `/obsidian-memory:toggle` vs. add a new `/obsidian-memory:scope`. This spec picks **a new `/obsidian-memory:scope` skill**, backed by `scripts/vault-scope.sh`, mirroring the toggle / doctor / teardown thin-relayer pattern. Rationale: toggle's feature whitelist is hard-coded to `rag` and `distill` (two booleans in two fixed stanzas). The scope operations target a third stanza (`projects`) whose shape is a mode string plus two string arrays, with verbs like `exclude add`, `allow remove`, `mode`, and `current`. Pressing those verbs into toggle's argv grammar would dilute toggle's "flip one boolean" contract and break its status output shape. A dedicated skill keeps each surface coherent and unit-testable in isolation.

---

## Acceptance Criteria

**IMPORTANT: Each criterion becomes a Gherkin BDD test scenario.**

### AC1: A project on the exclusion list is skipped by both hooks

**Given** `~/.claude/obsidian-memory/config.json` has `projects.mode = "all"` and `projects.excluded` contains `"acme-client"`
**And** the user is in a working directory whose derived slug is `acme-client`
**When** the user submits a prompt
**Then** `scripts/vault-rag.sh` exits 0 without emitting any `<vault-context>` block on stdout
**And** at session end, `scripts/vault-distill.sh` exits 0 without creating any file under `<vault>/claude-memory/sessions/acme-client/`
**And** `<vault>/claude-memory/Index.md` gets no new row from the skipped session.

**Example**:
- Given: `{"projects": {"mode": "all", "excluded": ["acme-client"]}, …}` and `CWD=/Users/me/projects/acme-client`
- When: UserPromptSubmit fires and SessionEnd fires later with a transcript > 2 KB
- Then: RAG hook stdout is empty; no new `.md` under `sessions/acme-client/`; `Index.md` unchanged by this session.

### AC2: Allowlist mode scopes the plugin to only listed projects

**Given** `projects.mode = "allowlist"` and `projects.allowed = ["obsidian-memory"]`
**When** the user works in a project whose slug is NOT in the allowlist (e.g., `random-repo`)
**Then** both hooks silently no-op — `vault-rag.sh` exits 0 with no `<vault-context>`, `vault-distill.sh` exits 0 with no file written.

**And** when the user works in an allowlisted project (slug `obsidian-memory`)
**Then** both hooks behave normally — RAG emits `<vault-context>` when notes match, distillation writes under `sessions/obsidian-memory/`.

### AC3: Default mode preserves existing behavior (no regression)

**Given** `projects.mode` is absent (or explicitly `"all"`) and `projects.excluded` / `projects.allowed` are absent or empty
**When** the user works in any project
**Then** both hooks behave exactly as they do today (v0.1 behavior) — no new guard short-circuits, no empty arrays silently reject every project.

**Example**:
- Given: a v0.1-shaped config with no `projects` stanza at all
- When: a prompt is submitted in any project
- Then: RAG behaves as before, distillation writes as before — the config upgrade is invisible.

### AC4: Project slug is derived deterministically and length-capped at 60

**Given** a working directory path `$CWD`
**When** the shared slug helper (`om_slug`) is called with `$CWD`
**Then** the returned slug matches `^[a-z0-9-]+$` (no leading/trailing hyphens, no consecutive hyphens)
**And** the slug length is ≤ 60 characters
**And** calling the helper twice with the same `$CWD` yields byte-identical output.

**Example**:
- Given: `$CWD = /Users/me/projects/My-Very-Long-Confidential_Client_Project_Name_With_Many_Characters`
- When: `om_slug "$CWD"` runs
- Then: result is `my-very-long-confidential-client-project-name-with-many-cha` (60 chars, all `[a-z0-9-]`, no trailing hyphen).

### AC5: Scope skill manages exclusions and allowlist without hand-editing JSON

**Given** a healthy config produced by `/obsidian-memory:setup`
**When** the user runs `/obsidian-memory:scope exclude add acme-client`
**Then** `projects.excluded` in the config contains `"acme-client"` (deduplicated; no duplicate entries if already present)
**And** the write is atomic (temp file in the same directory, then `mv` — same invariant as `vault-toggle.sh`)
**And** the skill exits 0 and prints a one-line confirmation (e.g., `projects.excluded: added "acme-client"`).

**And** the skill supports the full verb set without the user ever opening the JSON file:

| Invocation | Effect |
|------------|--------|
| `/obsidian-memory:scope` | Status — prints `mode`, current-project slug, excluded list, allowed list |
| `/obsidian-memory:scope status` | Same as above, explicit |
| `/obsidian-memory:scope current` | Prints the slug that would be used for the current `$PWD` |
| `/obsidian-memory:scope mode all` | Sets `projects.mode = "all"` |
| `/obsidian-memory:scope mode allowlist` | Sets `projects.mode = "allowlist"` |
| `/obsidian-memory:scope exclude add <slug>` | Appends `<slug>` to `projects.excluded` (dedup); `<slug>` defaults to the current-project slug if omitted |
| `/obsidian-memory:scope exclude remove <slug>` | Removes `<slug>` from `projects.excluded`; a no-op if not present |
| `/obsidian-memory:scope exclude list` | Prints `projects.excluded` one slug per line |
| `/obsidian-memory:scope allow add <slug>` | Appends `<slug>` to `projects.allowed` (dedup); defaults to current-project slug |
| `/obsidian-memory:scope allow remove <slug>` | Removes `<slug>` from `projects.allowed` |
| `/obsidian-memory:scope allow list` | Prints `projects.allowed` one slug per line |

### AC6: Mid-session overrides do not retroactively apply to the in-flight session

**Given** a Claude Code session has started on project `acme-client` while `projects.excluded` does NOT contain `acme-client`
**And** mid-session the user runs `/obsidian-memory:scope exclude add acme-client`
**When** the in-flight session later ends and its `SessionEnd` hook fires
**Then** the distill still runs for this session (the policy snapshot taken at session start determines the outcome, not the mid-session edit)
**And** subsequent sessions on the same project are correctly excluded.

**And** the inverse holds: excluding a project mid-session does not retroactively strip the `<vault-context>` block that was already injected into earlier prompts in that session.

**And** the scope skill's output includes the line `Note: overrides apply to sessions that start AFTER this change; the current session is unaffected.` whenever a mutation changes which bucket the current project falls into.

### AC7: Missing or malformed `projects` stanza falls back to "all"

**Given** a config where `projects` is absent, or `projects.mode` is a value other than `"all"` / `"allowlist"`, or `projects.excluded` / `projects.allowed` is not an array
**When** either hook runs
**Then** the hook treats the policy as `mode = "all"` with empty lists (no project is excluded, no allowlist gate)
**And** the hook logs a one-line stderr warning on malformed fields (e.g., `vault-rag.sh: projects.mode="weird" — treating as "all"`)
**And** the hook still exits 0 (per the "never block the user" invariant).

### AC8: Doctor reports mode and excluded count

**Given** a config with `projects.mode = "allowlist"`, `projects.excluded = ["a"]`, `projects.allowed = ["b", "c"]`
**When** the user runs `/obsidian-memory:doctor`
**Then** the report includes an `INFO` row for `scope_mode` showing `allowlist` and excluded/allowed counts (e.g., `scope_mode: allowlist (excluded: 1, allowed: 2)`)
**And** the `--json` output contains a `scope_mode` key with the same information.

**And** when `projects.mode` is `"all"` with empty lists, the row reads `scope_mode: all (unscoped)` and is still `INFO` (this is the default, not a failure).

### Generated Gherkin Preview

```gherkin
Feature: Per-Project Overrides (Exclude / Scope Config)
  As a Claude Code + Obsidian user who works on sensitive projects
  I want to exclude specific projects from RAG and distillation
  So that client code never ends up in my personal vault

  # one scenario per AC above
  # AC5 verb table becomes a Scenario Outline
```

---

## Functional Requirements

| ID  | Requirement | Priority | Notes |
|-----|-------------|----------|-------|
| FR1 | Extend `~/.claude/obsidian-memory/config.json` schema with a `projects` stanza: `projects.mode` ∈ `{"all", "allowlist"}` (default `"all"`), `projects.excluded: string[]` (default `[]`), `projects.allowed: string[]` (default `[]`). | Must | Shape defined in design.md → Data Model. |
| FR2 | Update `scripts/_common.sh` to export a new guard `om_project_allowed "$CWD"` that returns 0 when the hook should proceed, 1 when it should silently no-op. Every hook calls this after `om_load_config` but before doing work. | Must | Keeps the scope decision in one helper; both hooks share the same policy. |
| FR3 | Length-cap `om_slug` at 60 characters in `scripts/_common.sh`, aligning with `steering/structure.md` → Naming Conventions. Apply to every existing caller (distill's session-directory slug, scope's add/remove) so filenames and scope matching agree byte-for-byte. | Must | Regression guard: the distill hook currently relies on `om_slug`; its behavior becomes "same as before, but truncated at 60 chars" — no existing deployment should generate a slug longer than 60 in practice. |
| FR4 | Ship a new skill `skills/scope/SKILL.md` backed by `scripts/vault-scope.sh`, thin-relayer pattern (same shape as `skills/toggle/`, `skills/doctor/`, `skills/teardown/`). Verb set per AC5. | Must | Decision: new skill rather than extending toggle. See Background → UX decision. |
| FR5 | `scripts/vault-scope.sh` performs atomic writes: render new JSON to a temp file in the same directory as the config, then `mv` into place. An interrupted mutation leaves the original config untouched. An `EXIT` trap clears stray temp files. | Must | Same invariant as `vault-toggle.sh` FR5; reuse that script's structure verbatim where possible. |
| FR6 | `scripts/vault-scope.sh` preserves every unrelated key in the config byte-for-byte (uses `jq --indent 2`, same as toggle/setup). | Must | Regression guard: setup/doctor tests assert 2-space indent. |
| FR7 | Migration path: a config without a `projects` block is interpreted as `mode = "all"` with empty lists (FR2 guard returns 0 for every project). No migration step required; the hooks tolerate the missing stanza. | Must | Required by AC3 + AC7. |
| FR8 | Both `vault-rag.sh` (dispatcher) and `vault-distill.sh` call `om_project_allowed` and exit 0 silently (no `<vault-context>`, no vault writes) when it returns 1. The keyword and embedding RAG backend scripts (`vault-rag-keyword.sh`, `vault-rag-embedding.sh`) are NOT modified — the gate lives in the dispatcher so both backends inherit it. | Must | Keeps the one-script-swap retrieval invariant from `steering/product.md` intact. |
| FR9 | `vault-distill.sh` captures a policy snapshot at `SessionStart` (new hook) and reads the snapshot at `SessionEnd`, falling back to the live config when no snapshot exists (e.g., session predates the upgrade or snapshot write failed). Snapshots live under `~/.claude/obsidian-memory/session-policy/<session_id>.state` and are cleaned up opportunistically (no background reaper — stale snapshots are harmless). | Must | Required by AC6. |
| FR10 | `/obsidian-memory:doctor` gains a `scope_mode` INFO probe reporting mode + excluded/allowed counts, in both human and `--json` output. | Should | Required by AC8. Doctor remains read-only. |
| FR11 | BDD scenarios cover: excluded project (AC1), allowlist hit + miss (AC2), default-mode no-regression (AC3), slug determinism + length-cap (AC4), every row of the AC5 verb table (as a Scenario Outline), mid-session immunity (AC6), malformed config tolerance (AC7), doctor INFO row (AC8). | Must | Listed in tasks under the Testing phase. |
| FR12 | Invocations of `/obsidian-memory:scope` with an unknown verb, unknown mode value, or too many arguments print a usage line to stderr (first line starts with `ERROR:`) and exit 2. Missing config is a clean error: `ERROR: config not found — run /obsidian-memory:setup <vault> first`, exit 1. | Must | Aligns with the `vault-toggle.sh` exit-code contract (0 / 1 / 2). |
| FR13 | Slugs passed to `exclude add` / `allow add` are re-sanitized with `om_slug` before storage, so a user typing `scope exclude add Acme_Client` and a hook seeing `$CWD=/Users/me/projects/Acme_Client` agree on `acme-client`. | Must | Defense-in-depth against operator typos and double-sanitization. |

---

## Non-Functional Requirements

| Aspect | Requirement |
|--------|-------------|
| **Performance** | The scope-check guard (`om_project_allowed`) adds at most one extra `jq` invocation per hook call. Measured overhead on `vault-rag.sh` must stay within the p95 < 300 ms budget from `steering/tech.md` → Performance on a 1k-note vault. The guard short-circuits *before* any `rg`/`grep` work when a project is scoped out, so excluded projects are strictly faster. |
| **Security** | Slug storage and comparison always pass through `om_slug`. No prompt text, no raw `$CWD`, is ever stored in the config or interpolated into a shell command (per `steering/tech.md` → Security). The atomic-write invariant (FR5) guarantees the config cannot be left partially written by a malicious SIGKILL. |
| **Reliability** | Atomic writes (FR5), malformed-config tolerance (AC7 / FR7), and snapshot-with-fallback (FR9) collectively guarantee that no scope-related failure mode ever blocks the user. Every hook still exits 0 on every terminating path, per `steering/product.md` → Core Value Proposition #3. |
| **Platforms** | macOS default bash 3.2 and Linux bash 4+ per `steering/tech.md`. `jq ≥ 1.6` and BSD `mv` are the only required tools (already deps). No new dependencies. |

---

## UI/UX Requirements

The skill has no UI other than stdout/stderr. Output conventions mirror `vault-toggle.sh`:

| Element | Requirement |
|---------|-------------|
| **Mutation output** | `projects.<list>: added "<slug>"` / `projects.<list>: removed "<slug>"` / `projects.mode: <prev> -> <new>` on stdout. |
| **No-op output** | `projects.excluded already contains "<slug>"` / `projects.excluded did not contain "<slug>"` on stdout; still exit 0. |
| **Status output** | Four lines: `mode: <value>`, `current: <slug>`, `excluded: <comma-separated or (none)>`, `allowed: <comma-separated or (none)>`. |
| **Mid-session caveat** | Any mutation that changes the current project's bucket appends `Note: overrides apply to sessions that start AFTER this change; the current session is unaffected.` to stdout. |
| **Error output** | Everything to stderr. First line starts with `ERROR:`. |
| **Color** | None. The scope skill's output is plain text like toggle's. |

---

## Data Requirements

### Input Data

| Field | Type | Validation | Required |
|-------|------|------------|----------|
| `<verb>` | string argv | one of `status`, `current`, `mode`, `exclude`, `allow` | No (absent = `status`) |
| `<sub-verb>` | string argv | when `<verb>` is `exclude` or `allow`: one of `add`, `remove`, `list` | No (required when `<verb>` is `exclude`/`allow`) |
| `<slug>` | string argv | `[a-z0-9-]` after `om_slug` normalization; length ≤ 60 after normalization | No for `exclude add` / `allow add` (defaults to current-project slug); no for `remove` commands |
| `<mode-value>` | string argv | exactly `all` or `allowlist` | Yes when `<verb>` is `mode` |

### Config file touched

| Path | Keys read | Keys written |
|------|-----------|--------------|
| `~/.claude/obsidian-memory/config.json` | `.projects.mode`, `.projects.excluded`, `.projects.allowed` | `.projects.mode`, `.projects.excluded`, `.projects.allowed` (one field per mutation); every other key preserved byte-for-byte |

### New on-disk state

| Path | Purpose | Lifecycle |
|------|---------|-----------|
| `~/.claude/obsidian-memory/session-policy/<session_id>.state` | Policy snapshot taken at `SessionStart` — one line: `excluded` / `allowed` / `allowlist-miss` / `all`. Read at `SessionEnd` by `vault-distill.sh` before falling back to the live config. | Written by a new `SessionStart` hook; deleted by `vault-distill.sh` after `SessionEnd` consumes it. Stale leftovers are harmless — next session overwrites by ID. |

---

## Dependencies

### Internal Dependencies

- [x] `/obsidian-memory:setup` has written `~/.claude/obsidian-memory/config.json` (or is about to — `setup` is idempotent and will be updated to write an empty `projects` stanza going forward).
- [x] `jq ≥ 1.6` on `PATH`.
- [x] `scripts/_common.sh` slug + config-load helpers (modified by this feature).
- [x] `scripts/vault-rag.sh` dispatcher pattern from issue #5 (already shipped).

### External Dependencies

None. Scope is a local-only config mutator.

### Blocked By

None. Related but not blocking: issue #4 (toggle skill — already shipped as of commit `6a06fd4`), issue #2 (doctor skill — already shipped as of commit `9bcfe71`).

---

## Out of Scope

Explicit per the source issue:

- Per-project retrieval tuning (top-k, backend choice). That is a larger surface; not in v2 scope.
- Wildcard patterns in the allowlist (e.g., `clients/*`). Exact-slug only for v2.
- Time-boxed exclusions ("exclude this project for 2 hours"). Nice-to-have; not in scope.

Additional out-of-scope for this spec:

- Migrating existing long slugs on disk (slugs > 60 chars produced by pre-FR3 `om_slug`). FR3 affects new slugs only; distillation directories produced under the old helper stay where they are. Users who want consolidation can rename directories manually.
- A "kill switch" that disables scope checks without resetting the config. If needed, that belongs in toggle (`/obsidian-memory:toggle scope off`), which would be a follow-up issue.
- An automatic SessionStart snapshot garbage collector. Stale snapshots accumulate at most a few bytes per session; a dedicated cleanup task would trade operational complexity for negligible disk savings.
- Changing `vault-rag-keyword.sh` or `vault-rag-embedding.sh`. Per FR8, the gate lives in the dispatcher so retrieval backends remain swappable.

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| End-to-end time from "I need to exclude this project" to flag applied on next session | ≤ 10 s (one skill invocation, one session restart) | Self-measured; no instrumentation. |
| Config corruption events | 0 | Integration test asserts atomic-write invariant for every mutation verb. |
| RAG overhead when project is excluded | < 20 ms p95 | Integration test times the hook with a ≥ 1k-note vault and asserts the excluded path is strictly faster than the default path. |
| Mid-session immunity breakage | 0 reports of mid-session scope edits killing the in-flight distill | Manual verification during QA plus the AC6 BDD scenario. |

---

## Open Questions

- [ ] **Snapshot persistence location.** Design spec pins `~/.claude/obsidian-memory/session-policy/<session_id>.state`. Alternative: write it inside the transcript directory under `~/.claude/projects/`. The chosen location is simpler (single plugin-owned directory, no coordination with Claude Code's own transcript layout). Flagging here because it is the one architectural decision that could reasonably go either way; resolved in design.md → Alternatives Considered.

---

## Change History

| Issue | Date | Summary |
|-------|------|---------|
| #6 | 2026-04-22 | Initial feature spec |

---

## Validation Checklist

Before moving to PLAN phase:

- [x] User story follows "As a / I want / So that" format
- [x] All acceptance criteria use Given/When/Then format
- [x] No implementation details in requirements (FR-level file paths are deliberate — toggle-skill spec precedent)
- [x] All criteria are testable and unambiguous
- [x] Success metrics are measurable
- [x] Edge cases (mid-session, malformed config, default mode, length cap, dedup) are specified
- [x] Dependencies are identified
- [x] Out of scope is defined
- [x] Open questions are documented (or resolved in design)
