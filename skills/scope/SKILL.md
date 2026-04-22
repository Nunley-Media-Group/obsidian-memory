---
name: scope
description: Manage per-project exclusions and allowlists for obsidian-memory's RAG and distillation hooks without hand-editing config JSON. Use when the user says "exclude this project from obsidian memory", "don't distill this project", "scope obsidian memory to allowlist", "show scope status", "what's the current project slug", "stop leaking this project to my vault", "skip RAG for this repo", "add a project to the allowlist", "remove a project from the exclusion list", or invokes /obsidian-memory:scope.
argument-hint: [<verb> [<sub-verb>] [<slug>]]
allowed-tools: Bash, Read
model: sonnet
effort: low
---

# obsidian-memory: scope

Manage the `projects` stanza of `~/.claude/obsidian-memory/config.json` — per-project exclusions, an allowlist mode, and current-project slug resolution — without opening the JSON file. Scope is a **thin relayer**: every code path (argument parsing, slug normalization, atomic write, exit-code selection) lives in `scripts/vault-scope.sh`, which this skill invokes once and reports back verbatim. A user on a confidential client project can flip that one project out of RAG and distillation in a single command while leaving the zero-config default intact for every other project on the machine.

## When to Use

- The user is starting work on a confidential or client project and wants to exclude it from RAG injection and vault distillation without touching the global hook (`/obsidian-memory:scope exclude add`).
- The user wants to scope the plugin to a specific allowlist — e.g., one work project — and no-op on every other project (`/obsidian-memory:scope mode allowlist` + `/obsidian-memory:scope allow add <slug>`).
- The user wants to confirm the current mode, the current project's slug, and both lists in one glance (`/obsidian-memory:scope` or `/obsidian-memory:scope status`).
- The user wants to verify that a slug they are about to type matches the canonical form that `om_slug` would derive from their current working directory (`/obsidian-memory:scope current`).
- `/obsidian-memory:doctor` reported the `scope_mode` INFO row and the user wants to inspect or adjust it.

## When NOT to Use

- **To write the config from scratch.** Scope requires a config produced by `/obsidian-memory:setup`; a missing config is a clean error with a setup hint, not a silent create.
- **To flip the global `rag.enabled` / `distill.enabled` booleans.** Those belong to `/obsidian-memory:toggle`. Scope never touches the feature flags — only the `projects` stanza.
- **To change `vaultPath` or any key outside `projects.mode` / `projects.excluded` / `projects.allowed`.** Everything else in the config is still a hand-edit job (or a new skill).
- **To skip distillation for one specific session.** If the user only wants to opt out of a single distill rather than every future one in this project, `/obsidian-memory:distill-session` is the manual entry point — scoping the whole project out is heavier than needed.
- **To match projects by glob / wildcard, or to time-box an exclusion** ("exclude this project for 2 hours"). Those patterns are explicitly out of scope for v2; scope matches on exact slugs only.

## Invocation

```
/obsidian-memory:scope                               # status — prints mode, current slug, both lists
/obsidian-memory:scope status                        # same as above, explicit
/obsidian-memory:scope current                       # print just the current $PWD's canonical slug
/obsidian-memory:scope mode all                      # set projects.mode = "all"
/obsidian-memory:scope mode allowlist                # set projects.mode = "allowlist"
/obsidian-memory:scope exclude add [<slug>]          # add to excluded (defaults to current project)
/obsidian-memory:scope exclude remove [<slug>]       # remove from excluded
/obsidian-memory:scope exclude list                  # one slug per line
/obsidian-memory:scope allow add [<slug>]            # add to allowed (defaults to current project)
/obsidian-memory:scope allow remove [<slug>]         # remove from allowed
/obsidian-memory:scope allow list                    # one slug per line
```

`<slug>` on `exclude add` / `allow add` is optional and defaults to the canonical slug for the current working directory. Whatever the user types — a basename, a full path, a name with mixed case or underscores — is re-normalized through `om_slug` before it's written, so the stored form is always `[a-z0-9-]`, collapsed, and ≤ 60 characters.

## Behavior

1. Invoke `"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/obsidian-memory}/scripts/vault-scope.sh" "$@"` so every positional argument passes through verbatim. Do not re-parse the arguments and do not re-run the script.
2. Relay the script's stdout and exit code directly. If the exit code is non-zero, summarize the specific failing reason in a single line (e.g., "scope failed: config not found — run `/obsidian-memory:setup <vault>` first") so the user does not have to re-read the full output, but never substitute your own interpretation for the script's message.
3. On a successful mutation the script prints `projects.<list>: added "<slug>"` / `projects.<list>: removed "<slug>"` / `projects.mode: <prev> -> <new>` on stdout. An already-in-state call prints `projects.<list> already contains "<slug>"` (or the symmetric "did not contain" for removals) — still a success, still exit 0. Status reads print four lines: `mode`, `current`, `excluded`, `allowed`.
4. When a mutation changes which policy bucket the current project falls into, the script appends one extra stdout line: `Note: overrides apply to sessions that start AFTER this change; the current session is unaffected.` Relay that line as-is — it is the user-facing signal that AC6 mid-session immunity is in effect.

All logic — argument parsing, slug canonicalization, dedup on `add`, no-op detection on `remove`, atomic write, mid-session-caveat decision, and the empty-allowlist warning — lives in `scripts/vault-scope.sh`. Keeping the SKILL body free of logic is what lets the bats and cucumber-shell tests exercise every path deterministically without a live Claude session.

## Exit Code Contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Success — a status read, a successful mutation, or the "already contains" / "did not contain" no-op. |
| `1` | Runtime error — config missing, config unreadable, `jq` missing, or the atomic write failed. The config on disk is unchanged. |
| `2` | Bad usage — unknown verb, unknown sub-verb, unknown mode value, or too many positional arguments. No read or write was attempted. |

The first line of stderr on any error always starts with the literal `ERROR:` prefix, which makes the output grep-friendly for anyone scripting around it.

## Error handling

- **Missing config** (`~/.claude/obsidian-memory/config.json` does not exist): the script prints `ERROR: config not found — run /obsidian-memory:setup <vault> first` to stderr and exits 1. Nothing is created under `~/.claude/obsidian-memory/` — re-running `/obsidian-memory:setup` is the only way forward.
- **Missing `jq`**: exits 1 with an install hint (`brew install jq`). Scope will not attempt a write without `jq` because the atomic-write guarantee (temp file + `mv`) depends on `jq --indent 2` to render the new body.
- **Unknown verb, sub-verb, or mode value**: exits 2 with a usage line naming the allowed values. The config is not read for content and not rewritten.
- **Failed write** (rare — out of disk, permissions, or a concurrent process holding the path): the atomic-write idiom guarantees the original config is never truncated or partially overwritten. The script exits 1; an `EXIT` trap clears any stray `.tmp.$$` artifact from the config directory.
- **`mode allowlist` with an empty `allowed` list**: the script still completes the mode flip (exit 0) but emits a `WARNING:` on stderr — `allowlist mode with no allowed projects — all projects will no-op`. This is intentionally non-fatal; a user may be in the middle of setting up a fresh allowlist and want the warning rather than a refusal.

## Idempotency

Scope is idempotent by construction:

- `/obsidian-memory:scope exclude add acme-client` against a config where `projects.excluded` already contains `"acme-client"` is a no-op — the script prints `projects.excluded already contains "acme-client"` and exits 0 **without rewriting the file** (`mtime` and inode are preserved; downstream tools watching the config for changes stay quiet).
- `/obsidian-memory:scope exclude remove acme-client` against a list that does not contain `"acme-client"` prints `projects.excluded did not contain "acme-client"` and exits 0 without a write.
- `/obsidian-memory:scope mode allowlist` when the mode is already `allowlist` prints `projects.mode was already allowlist` and exits 0 without a write.
- `status`, `current`, and `<list> list` never write, so they are safe to run in a loop (e.g., from a `watch` command or a health check).
- The mutation path writes to a temp file in the same directory as the config, then `mv`s it into place — an interrupted scope edit (up to and including SIGKILL between the write and the rename) leaves the original config intact rather than corrupted.

## Slug normalization

Every slug that enters or leaves the config passes through the shared `om_slug` helper in `scripts/_common.sh`: `basename` → lowercase → non-alphanumerics collapsed to `-` → length-capped at 60 characters → trailing hyphens stripped. That single helper is used by the distill hook when it names a session directory, by the session-start hook when it snapshots policy, and by scope when it reads or writes the lists — so the name the user types, the name on disk, and the name stored in config are always byte-identical. Concretely: `scope exclude add Acme_Client`, `scope exclude add /Users/me/projects/Acme_Client`, and a distill session whose `cwd=/Users/me/projects/Acme_Client` all agree on `acme-client`.

This is what makes the "defaults to current project" shortcut safe — the script canonicalizes `$PWD` with the same helper that the hooks use, so the stored slug always matches the runtime check.

## Mid-session caveat

Scope edits do not retroactively apply to the in-flight Claude Code session. The SessionStart hook (`scripts/vault-session-start.sh`) writes a one-line policy snapshot (`all` / `excluded` / `allowlist-hit` / `allowlist-miss`) to `~/.claude/obsidian-memory/session-policy/<session_id>.state`; the distill hook reads that snapshot at SessionEnd before it consults the live config. A user who runs `/obsidian-memory:scope exclude add mid-project` midway through a session still gets the in-flight session's distillation written — only the *next* session on `mid-project` will be excluded.

RAG injection, by contrast, reads the *live* config on every prompt, because a user who excludes mid-session wants to stop leaking context on the next prompt. The mid-session caveat only covers the durable distillation artifact.

When a scope mutation moves the current project's slug from one policy bucket to another, `vault-scope.sh` appends the caveat line automatically — `Note: overrides apply to sessions that start AFTER this change; the current session is unaffected.` — so the user always sees the SessionEnd-vs-next-session split called out without having to remember the rule.

## Related skills

- `/obsidian-memory:setup` writes the initial `~/.claude/obsidian-memory/config.json` that scope reads and mutates. The config it writes already includes an empty `projects` stanza (`{"mode": "all", "excluded": [], "allowed": []}`), so scope's first mutation against a fresh install does not need to synthesize the stanza. A missing config points the user back to setup; there is no auto-creation path.
- `/obsidian-memory:toggle` flips the *global* `rag.enabled` and `distill.enabled` flags. Scope and toggle are complementary: toggle turns the hook on or off for every project; scope decides which projects the hook acts on when it is on. A user who wants to pause everything briefly should prefer `toggle`; a user who wants one persistent exclusion should prefer `scope`.
- `/obsidian-memory:doctor` reports the current `scope_mode` as an INFO probe — human output reads `scope_mode: all (unscoped)` by default or `<mode> (excluded: N, allowed: M)` when the lists are populated, and `--json` exposes the same under the `scope_mode` key. Doctor is read-only; when the user wants to change what doctor reported, the next step is scope.
- `/obsidian-memory:distill-session` runs the distillation on demand for the most recent transcript. If the user wants to skip a single session's distill without excluding the whole project, simply not running `distill-session` is lighter than adding a scope entry and removing it after.
